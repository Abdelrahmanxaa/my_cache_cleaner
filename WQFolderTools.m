//
//  WQFolderTools.m
//  WQ Files: folder tools (storage breakdown, duplicates, old files, compare,
//  bulk rename), colored tags, backup retention and the app info screen.
//  GPL-3.0-or-later.
//

#import "WQTools.h"
#import "WQUI.h"
#import "WQAccess.h"
#import "WQAccessSafety.h"
#import "WQDir.h"
#import "WQLaunchServices.h"
#import "WQHealth.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

#pragma mark - Helpers

static NSString *wq_ft_age_text(time_t modified)
{
    long days = (long)((time(NULL) - modified) / 86400);
    if (days < 1) return WQLocalized(@"today");
    if (days == 1) return WQLocalized(@"1 day ago");
    if (days < 365) return WQLocalizedFormat(@"%ld days ago", days);
    return WQLocalizedFormat(@"%ld years ago", days / 365);
}

// Calls `visit` for every regular file below root (symbolic links and backup
// storage are skipped). Returns NO when cancelled.
static BOOL wq_ft_walk(NSString *root, WQScanCancellation *cancel, NSUInteger limit,
                       void (^visit)(NSString *path, const struct stat *st))
{
    BOOL rootInBackups = wq_is_backup_storage_path(root);
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger seen = 0;
    while (stack.count) {
        if (cancel.isCancelled) return NO;
        NSString *dir = stack.lastObject;
        [stack removeLastObject];
        NSArray<NSString *> *names = wq_list(dir, NULL);
        for (NSString *name in names) {
            if (cancel.isCancelled) return NO;
            NSString *path = [dir stringByAppendingPathComponent:name];
            struct stat st;
            if (!wq_stat(path, &st) || S_ISLNK(st.st_mode)) continue;
            if (S_ISDIR(st.st_mode)) {
                if (!rootInBackups && wq_is_backup_storage_path(path)) continue;
                [stack addObject:path];
                continue;
            }
            if (!S_ISREG(st.st_mode)) continue;
            visit(path, &st);
            if (++seen >= limit) return YES;
        }
    }
    return YES;
}

static NSData *wq_ft_sha256(NSString *path, WQScanCancellation *cancel)
{
    int fd = wq_open_for_reading(path);
    if (fd < 0) return nil;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    const size_t chunk = 256 * 1024;
    uint8_t *buffer = malloc(chunk);
    if (!buffer) { close(fd); return nil; }
    BOOL ok = YES;
    ssize_t got;
    while ((got = read(fd, buffer, chunk)) > 0) {
        CC_SHA256_Update(&ctx, buffer, (CC_LONG)got);
        if (cancel.isCancelled) { ok = NO; break; }
    }
    if (got < 0) ok = NO;
    free(buffer);
    close(fd);
    if (!ok) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    return [NSData dataWithBytes:digest length:sizeof digest];
}

// Rows are dictionaries: title, detail, path (the item), open (the folder to
// show for it), noDelete (YES hides Delete).
static NSDictionary *wq_ft_row(NSString *title, NSString *detail, NSString *path, NSString *open, BOOL noDelete)
{
    return @{@"title": title ?: @"", @"detail": detail ?: @"", @"path": path ?: @"",
             @"open": open ?: @"", @"noDelete": @(noDelete)};
}

static NSString *wq_ft_relative(NSString *root, NSString *path)
{
    if ([path hasPrefix:root] && path.length > root.length) {
        NSString *rest = [path substringFromIndex:root.length];
        return [rest hasPrefix:@"/"] ? [rest substringFromIndex:1] : rest;
    }
    return path;
}

#pragma mark - Results screen

typedef NSArray<NSDictionary *> *(^WQToolWork)(WQScanCancellation *cancel, void (^status)(NSString *text));

@interface WQToolResultsViewController : UITableViewController
- (instancetype)initWithTitle:(NSString *)title readOnly:(BOOL)readOnly work:(WQToolWork)work;
@end

@implementation WQToolResultsViewController {
    NSString *_toolTitle;
    BOOL _readOnly;
    WQToolWork _work;
    WQScanCancellation *_cancel;
    NSMutableArray<NSMutableDictionary *> *_sections;   // header, rows (mutable)
}

- (instancetype)initWithTitle:(NSString *)title readOnly:(BOOL)readOnly work:(WQToolWork)work
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _toolTitle = [title copy];
        _readOnly = readOnly;
        _work = [work copy];
        _cancel = [WQScanCancellation new];
        _sections = [NSMutableArray new];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(_toolTitle);
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = [UIColor clearColor];
    }
    self.navigationItem.prompt = WQLocalizedNullable(@"Scanning…");
    WQScanCancellation *cancel = _cancel;
    WQToolWork work = _work;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __block CFAbsoluteTime lastUpdate = 0;
        NSArray<NSDictionary *> *sections = work(cancel, ^(NSString *text) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastUpdate < 0.4) return;
            lastUpdate = now;
            dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.navigationItem.prompt = text; });
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSUInteger total = 0;
            for (NSDictionary *section in sections) {
                NSMutableDictionary *copy = [section mutableCopy];
                copy[@"rows"] = [section[@"rows"] mutableCopy];
                total += [section[@"rows"] count];
                [strongSelf->_sections addObject:copy];
            }
            strongSelf.navigationItem.prompt = cancel.isCancelled ? WQLocalizedNullable(@"Stopped")
                : total ? WQLocalizedFormat(@"%lu results", (unsigned long)total) : WQLocalizedNullable(@"Nothing found");
            [strongSelf.tableView reloadData];
        });
    });
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController) [_cancel cancel];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return (NSInteger)[_sections[(NSUInteger)section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return _sections[(NSUInteger)section][@"header"];
}

- (NSDictionary *)rowAt:(NSIndexPath *)indexPath
{
    return _sections[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"res"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"res"];
    NSDictionary *row = [self rowAt:indexPath];
    NSString *marker = wq_tag_marker(row[@"path"]);
    cell.textLabel.text = marker ? [NSString stringWithFormat:@"%@ %@", marker, row[@"title"]] : row[@"title"];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = row[@"detail"];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = [self rowAt:indexPath];
    NSString *path = row[@"path"], *open = row[@"open"];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UIAlertController *sheet = wq_alert_controller(WQVerbatim(path.lastPathComponent), WQVerbatim(path), UIAlertControllerStyleActionSheet);
    __weak typeof(self) weakSelf = self;
    if (open.length) {
        [sheet addAction:wq_alert_action(@"Open Folder", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            WQDirViewController *folder = [[WQDirViewController alloc] initWithPath:open title:open.lastPathComponent];
            folder.readOnly = strongSelf->_readOnly;
            [strongSelf.navigationController pushViewController:folder animated:YES];
        })];
    }
    [sheet addAction:wq_alert_action(@"Copy Path", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        UIPasteboard.generalPasteboard.string = path;
    })];
    if (!_readOnly && wq_deleting_allowed() && ![row[@"noDelete"] boolValue] && path.length) {
        [sheet addAction:wq_alert_action(@"Delete…", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
            [weakSelf confirmDelete:path indexPath:indexPath];
        })];
    }
    [sheet addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

// The normal confirmation, then (like everywhere else) a second warning when
// the delete could harm an app, WQ Files or iOS.
- (void)confirmDelete:(NSString *)path indexPath:(NSIndexPath *)indexPath
{
    if (wq_refuse_if_deleting_off(self)) return;
    __weak typeof(self) weakSelf = self;
    UIAlertController *alert = wq_alert_controller(@"Delete this file?",
        WQVerbatim([NSString stringWithFormat:@"%@\n\n%@", path, WQLocalized(@"It is saved in Recently Deleted first, so it can be restored.")]),
        UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Delete", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        NSString *risk = wq_delete_risk_text(@[path]);
        if (!risk.length) { [weakSelf performDelete:path indexPath:indexPath]; return; }
        UIAlertController *second = wq_alert_controller(@"This could cause problems", WQVerbatim(risk), UIAlertControllerStyleAlert);
        [second addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
        [second addAction:wq_alert_action(@"Delete Anyway", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused b) {
            [weakSelf performDelete:path indexPath:indexPath];
        })];
        [weakSelf presentViewController:second animated:YES completion:nil];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performDelete:(NSString *)path indexPath:(NSIndexPath *)indexPath
{
    if (!wq_deleting_allowed()) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        BOOL ok = wq_delete(path, &error);
        wq_log(@"folder tools: delete %@: %@", path, ok ? @"OK" : (error ?: @"failed"));
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!ok) { wq_alert(strongSelf, @"Not deleted", WQVerbatim(error ?: @"See Log")); return; }
            // The row may have moved; find it again by path.
            for (NSUInteger s = 0; s < strongSelf->_sections.count; s++) {
                NSMutableArray *rows = strongSelf->_sections[s][@"rows"];
                for (NSUInteger r = 0; r < rows.count; r++) {
                    if ([rows[r][@"path"] isEqualToString:path]) {
                        [rows removeObjectAtIndex:r];
                        [strongSelf.tableView reloadData];
                        return;
                    }
                }
            }
            (void)indexPath;
        });
    });
}

@end

#pragma mark - Storage breakdown

static NSArray<NSDictionary *> *wq_ft_storage(NSString *root, WQScanCancellation *cancel, void (^status)(NSString *))
{
    NSArray<NSString *> *names = wq_list(root, NULL) ?: @[];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray new];
    unsigned long long total = 0;
    NSUInteger index = 0;
    for (NSString *name in names) {
        if (cancel.isCancelled) break;
        index++;
        status([NSString stringWithFormat:@"%@ (%lu/%lu)", name, (unsigned long)index, (unsigned long)names.count]);
        NSString *path = [root stringByAppendingPathComponent:name];
        struct stat st;
        if (!wq_stat(path, &st) || S_ISLNK(st.st_mode)) continue;
        BOOL dir = S_ISDIR(st.st_mode);
        unsigned long long bytes = 0;
        if (dir) (void)wq_measure_tree(path, cancel, &bytes);
        else if (S_ISREG(st.st_mode)) bytes = (unsigned long long)st.st_size;
        else continue;
        total += bytes;
        [items addObject:@{@"name": name, @"bytes": @(bytes), @"dir": @(dir), @"path": path}];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"bytes"] compare:a[@"bytes"]];
    }];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
    for (NSDictionary *item in items) {
        unsigned long long bytes = [item[@"bytes"] unsignedLongLongValue];
        double percent = total ? 100.0 * (double)bytes / (double)total : 0;
        BOOL dir = [item[@"dir"] boolValue];
        NSString *detail = [NSString stringWithFormat:@"%@ · %.1f%%", wq_size_text(bytes), percent];
        [rows addObject:wq_ft_row(dir ? [item[@"name"] stringByAppendingString:@"/"] : item[@"name"], detail, item[@"path"],
                                  dir ? item[@"path"] : root, dir)];
    }
    return @[@{@"header": WQLocalizedFormat(@"Total: %@", wq_size_text(total)), @"rows": rows}];
}

#pragma mark - Duplicates

static NSArray<NSDictionary *> *wq_ft_duplicates(NSString *root, WQScanCancellation *cancel, void (^status)(NSString *))
{
    NSMutableDictionary<NSNumber *, NSMutableArray<NSString *> *> *bySize = [NSMutableDictionary new];
    __block NSUInteger counted = 0;
    BOOL finished = wq_ft_walk(root, cancel, 300000, ^(NSString *path, const struct stat *st) {
        if (st->st_size < 1024 || st->st_size > (off_t)512 * 1024 * 1024) return;
        NSNumber *key = @((long long)st->st_size);
        NSMutableArray<NSString *> *list = bySize[key];
        if (!list) bySize[key] = list = [NSMutableArray new];
        [list addObject:path];
        if (++counted % 200 == 0) status(WQLocalizedFormat(@"Reading… %lu files", (unsigned long)counted));
    });
    if (!finished) return @[];
    NSMutableArray<NSDictionary *> *groups = [NSMutableArray new];
    NSUInteger candidates = 0, done = 0;
    for (NSArray<NSString *> *list in bySize.allValues) if (list.count > 1) candidates += list.count;
    for (NSNumber *size in bySize) {
        NSArray<NSString *> *list = bySize[size];
        if (list.count < 2) continue;
        NSMutableDictionary<NSData *, NSMutableArray<NSString *> *> *byHash = [NSMutableDictionary new];
        for (NSString *path in list) {
            if (cancel.isCancelled) return @[];
            status(WQLocalizedFormat(@"Comparing… %lu/%lu", (unsigned long)++done, (unsigned long)candidates));
            NSData *digest = wq_ft_sha256(path, cancel);
            if (!digest) continue;
            NSMutableArray<NSString *> *same = byHash[digest];
            if (!same) byHash[digest] = same = [NSMutableArray new];
            [same addObject:path];
        }
        for (NSArray<NSString *> *same in byHash.allValues)
            if (same.count > 1) [groups addObject:@{@"size": size, @"paths": [same sortedArrayUsingSelector:@selector(compare:)]}];
    }
    [groups sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        unsigned long long wa = [a[@"size"] unsignedLongLongValue] * ([a[@"paths"] count] - 1);
        unsigned long long wb = [b[@"size"] unsignedLongLongValue] * ([b[@"paths"] count] - 1);
        return wa == wb ? NSOrderedSame : (wa > wb ? NSOrderedAscending : NSOrderedDescending);
    }];
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray new];
    for (NSDictionary *group in groups) {
        if (sections.count >= 100) break;
        unsigned long long size = [group[@"size"] unsignedLongLongValue];
        NSArray<NSString *> *paths = group[@"paths"];
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
        for (NSString *path in paths)
            [rows addObject:wq_ft_row(wq_ft_relative(root, path), wq_size_text(size), path, path.stringByDeletingLastPathComponent, NO)];
        NSString *header = WQLocalizedFormat(@"%lu identical files · %@ each · %@ could be freed", (unsigned long)paths.count,
                                             wq_size_text(size), wq_size_text(size * (paths.count - 1)));
        [sections addObject:@{@"header": header, @"rows": rows}];
    }
    return sections;
}

#pragma mark - Old files

static NSArray<NSDictionary *> *wq_ft_old_files(NSString *root, NSInteger days, WQScanCancellation *cancel, void (^status)(NSString *))
{
    time_t cutoff = time(NULL) - (time_t)days * 86400;
    NSMutableArray<NSDictionary *> *found = [NSMutableArray new];
    __block NSUInteger counted = 0;
    BOOL finished = wq_ft_walk(root, cancel, 500000, ^(NSString *path, const struct stat *st) {
        if (++counted % 300 == 0) status(WQLocalizedFormat(@"Reading… %lu files", (unsigned long)counted));
        if (st->st_mtime >= cutoff) return;
        [found addObject:@{@"path": path, @"size": @((long long)st->st_size), @"mtime": @((long long)st->st_mtime)}];
    });
    if (!finished) return @[];
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"size"] compare:a[@"size"]]; }];
    unsigned long long total = 0;
    for (NSDictionary *item in found) total += [item[@"size"] unsignedLongLongValue];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
    for (NSDictionary *item in found) {
        if (rows.count >= 500) break;
        NSString *path = item[@"path"];
        NSString *detail = [NSString stringWithFormat:@"%@ · %@", wq_size_text([item[@"size"] unsignedLongLongValue]),
                            wq_ft_age_text((time_t)[item[@"mtime"] longLongValue])];
        [rows addObject:wq_ft_row(wq_ft_relative(root, path), detail, path, path.stringByDeletingLastPathComponent, NO)];
    }
    return @[@{@"header": WQLocalizedFormat(@"%lu files not changed for %ld days · %@", (unsigned long)found.count, (long)days, wq_size_text(total)),
               @"rows": rows}];
}

#pragma mark - Compare folders

static NSString *sMarkedFolder;

static NSDictionary<NSString *, NSNumber *> *wq_ft_index(NSString *root, WQScanCancellation *cancel, NSMutableDictionary<NSString *, NSString *> *paths)
{
    NSMutableDictionary<NSString *, NSNumber *> *index = [NSMutableDictionary new];
    BOOL finished = wq_ft_walk(root, cancel, 200000, ^(NSString *path, const struct stat *st) {
        NSString *relative = wq_ft_relative(root, path);
        index[relative] = @((long long)st->st_size);
        paths[relative] = path;
    });
    return finished ? index : nil;
}

static NSArray<NSDictionary *> *wq_ft_compare(NSString *a, NSString *b, WQScanCancellation *cancel, void (^status)(NSString *))
{
    status(WQLocalized(@"Reading the first folder…"));
    NSMutableDictionary<NSString *, NSString *> *pathsA = [NSMutableDictionary new], *pathsB = [NSMutableDictionary new];
    NSDictionary<NSString *, NSNumber *> *indexA = wq_ft_index(a, cancel, pathsA);
    if (!indexA) return @[];
    status(WQLocalized(@"Reading the second folder…"));
    NSDictionary<NSString *, NSNumber *> *indexB = wq_ft_index(b, cancel, pathsB);
    if (!indexB) return @[];
    NSMutableArray<NSDictionary *> *onlyA = [NSMutableArray new], *onlyB = [NSMutableArray new], *different = [NSMutableArray new];
    NSUInteger countA = 0, countB = 0, countDiff = 0;
    for (NSString *relative in [indexA.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSNumber *sizeB = indexB[relative];
        NSString *path = pathsA[relative];
        if (!sizeB) {
            countA++;
            if (onlyA.count < 500) [onlyA addObject:wq_ft_row(relative, wq_size_text([indexA[relative] unsignedLongLongValue]), path, path.stringByDeletingLastPathComponent, NO)];
        } else if (![sizeB isEqual:indexA[relative]]) {
            countDiff++;
            if (different.count < 500) {
                NSString *detail = [NSString stringWithFormat:@"%@ ↔ %@", wq_size_text([indexA[relative] unsignedLongLongValue]), wq_size_text([sizeB unsignedLongLongValue])];
                [different addObject:wq_ft_row(relative, detail, path, path.stringByDeletingLastPathComponent, NO)];
            }
        }
    }
    for (NSString *relative in [indexB.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (indexA[relative]) continue;
        countB++;
        NSString *path = pathsB[relative];
        if (onlyB.count < 500) [onlyB addObject:wq_ft_row(relative, wq_size_text([indexB[relative] unsignedLongLongValue]), path, path.stringByDeletingLastPathComponent, NO)];
    }
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray new];
    if (onlyA.count) [sections addObject:@{@"header": WQLocalizedFormat(@"Only in %@ (%lu)", a.lastPathComponent, (unsigned long)countA), @"rows": onlyA}];
    if (onlyB.count) [sections addObject:@{@"header": WQLocalizedFormat(@"Only in %@ (%lu)", b.lastPathComponent, (unsigned long)countB), @"rows": onlyB}];
    if (different.count) [sections addObject:@{@"header": WQLocalizedFormat(@"Different size (%lu)", (unsigned long)countDiff), @"rows": different}];
    return sections;
}

#pragma mark - Tags

static NSArray<NSString *> *wq_ft_tag_markers(void) { return @[@"🔴", @"🟠", @"🟡", @"🟢", @"🔵", @"🟣"]; }
static NSArray<NSString *> *wq_ft_tag_names(void) { return @[@"Red", @"Orange", @"Yellow", @"Green", @"Blue", @"Purple"]; }

static NSString *wq_ft_tag_key(NSString *path)
{
    if ([path hasPrefix:@"/private/var/"]) return [path substringFromIndex:8];
    return path;
}

static NSString *wq_ft_tags_file(void)
{
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"Tags.plist"];
}

static NSMutableDictionary<NSString *, NSNumber *> *wq_ft_tags(void)
{
    static NSMutableDictionary<NSString *, NSNumber *> *tags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:wq_ft_tags_file()];
        tags = saved ? [saved mutableCopy] : [NSMutableDictionary new];
    });
    return tags;
}

NSString *wq_tag_marker(NSString *path)
{
    if (!path.length) return nil;
    NSNumber *index;
    @synchronized (NSFileManager.class) { index = wq_ft_tags()[wq_ft_tag_key(path)]; }
    NSArray<NSString *> *markers = wq_ft_tag_markers();
    if (!index || index.integerValue < 0 || (NSUInteger)index.integerValue >= markers.count) return nil;
    return markers[(NSUInteger)index.integerValue];
}

static void wq_ft_set_tag(NSString *path, NSInteger index)
{
    @synchronized (NSFileManager.class) {
        NSMutableDictionary<NSString *, NSNumber *> *tags = wq_ft_tags();
        if (index < 0) [tags removeObjectForKey:wq_ft_tag_key(path)];
        else tags[wq_ft_tag_key(path)] = @(index);
        [tags writeToFile:wq_ft_tags_file() atomically:YES];
    }
}

UIMenu *wq_tag_menu(NSString *path, void (^changed)(void))
{
    NSString *key = [path copy];
    NSString *current = wq_tag_marker(key);
    NSArray<NSString *> *markers = wq_ft_tag_markers(), *names = wq_ft_tag_names();
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray new];
    for (NSUInteger i = 0; i < markers.count; i++) {
        UIAction *action = [UIAction actionWithTitle:[NSString stringWithFormat:@"%@ %@", markers[i], WQLocalized(names[i])] image:nil identifier:nil
                                             handler:^(UIAction *__unused a) {
            wq_ft_set_tag(key, (NSInteger)i);
            if (changed) changed();
        }];
        if ([current isEqualToString:markers[i]]) action.state = UIMenuElementStateOn;
        [actions addObject:action];
    }
    if (current) {
        [actions addObject:[UIAction actionWithTitle:WQLocalized(@"Remove Tag") image:[UIImage systemImageNamed:@"tag.slash"] identifier:nil
                                             handler:^(UIAction *__unused a) {
            wq_ft_set_tag(key, -1);
            if (changed) changed();
        }]];
    }
    return [UIMenu menuWithTitle:WQLocalized(@"Tag") image:[UIImage systemImageNamed:@"tag"] identifier:nil options:0 children:actions];
}

static NSArray<NSDictionary *> *wq_ft_tagged_items(void)
{
    NSDictionary<NSString *, NSNumber *> *snapshot;
    @synchronized (NSFileManager.class) { snapshot = [wq_ft_tags() copy]; }
    NSArray<NSString *> *markers = wq_ft_tag_markers(), *names = wq_ft_tag_names();
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray new];
    for (NSUInteger i = 0; i < markers.count; i++) {
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
        for (NSString *path in [snapshot.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if ((NSUInteger)[snapshot[path] integerValue] != i) continue;
            struct stat st;
            if (!wq_stat(path, &st)) continue;
            [rows addObject:wq_ft_row(path.lastPathComponent, path, path, S_ISDIR(st.st_mode) ? path : path.stringByDeletingLastPathComponent, YES)];
        }
        if (rows.count) [sections addObject:@{@"header": [NSString stringWithFormat:@"%@ %@", markers[i], WQLocalized(names[i])], @"rows": rows}];
    }
    return sections;
}

#pragma mark - Bulk rename

static NSString *wq_ft_new_name(NSString *name, NSString *find, NSString *replace, NSString *prefix, NSString *suffix)
{
    NSString *base = name.stringByDeletingPathExtension, *ext = name.pathExtension;
    if (!base.length) return name;
    NSString *middle = find.length ? [base stringByReplacingOccurrencesOfString:find withString:replace ?: @""] : base;
    NSString *renamed = [NSString stringWithFormat:@"%@%@%@", prefix ?: @"", middle, suffix ?: @""];
    return ext.length ? [renamed stringByAppendingPathExtension:ext] : renamed;
}

@interface WQBulkRenameViewController : UITableViewController
- (instancetype)initWithFolder:(NSString *)folder;
@end

@implementation WQBulkRenameViewController {
    NSString *_folder;
    NSArray<NSString *> *_names;
    NSArray<UITextField *> *_fields;   // find, replace, prefix, suffix
    NSArray<NSArray<NSString *> *> *_changes;   // [old, new]
}

- (instancetype)initWithFolder:(NSString *)folder
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _folder = [folder copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(@"Bulk Rename");
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = [UIColor clearColor];
    }
    NSMutableArray<UITextField *> *fields = [NSMutableArray new];
    NSArray<NSString *> *placeholders = @[@"Find", @"Replace with", @"Add before the name", @"Add after the name"];
    for (NSString *placeholder in placeholders) {
        UITextField *field = [UITextField new];
        field.placeholder = WQLocalized(placeholder);
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        [field addTarget:self action:@selector(fieldChanged) forControlEvents:UIControlEventEditingChanged];
        [fields addObject:field];
    }
    _fields = fields;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalized(@"Rename") style:UIBarButtonItemStyleDone
                                                                              target:self action:@selector(confirmRename)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    NSArray<NSString *> *names = wq_list(_folder, NULL) ?: @[];
    _names = [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    [self recompute];
}

- (void)fieldChanged
{
    [self recompute];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)recompute
{
    NSString *find = _fields[0].text, *replace = _fields[1].text, *prefix = _fields[2].text, *suffix = _fields[3].text;
    NSMutableArray<NSArray<NSString *> *> *changes = [NSMutableArray new];
    NSMutableSet<NSString *> *taken = [NSMutableSet setWithArray:_names];
    for (NSString *name in _names) {
        NSString *renamed = wq_ft_new_name(name, find, replace, prefix, suffix);
        if (!renamed.length || [renamed isEqualToString:name] || [renamed containsString:@"/"]) continue;
        [changes addObject:@[name, renamed]];
        if (changes.count >= 2000) break;
    }
    (void)taken;
    _changes = changes;
    self.navigationItem.rightBarButtonItem.enabled = changes.count > 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return section == 0 ? (NSInteger)_fields.count : (NSInteger)MIN(_changes.count, (NSUInteger)300);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) return WQLocalized(@"Changes apply to the name without its extension");
    return _changes.count ? WQLocalizedFormat(@"%lu items will be renamed", (unsigned long)_changes.count) : WQLocalized(@"Nothing to rename yet");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [UITableViewCell new];
        UITextField *field = _fields[(NSUInteger)indexPath.row];
        field.frame = CGRectMake(16, 0, 300, 44);
        field.translatesAutoresizingMaskIntoConstraints = NO;
        [field removeFromSuperview];
        [cell.contentView addSubview:field];
        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [field.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
            [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
            [field.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        ]];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"change"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"change"];
    NSArray<NSString *> *pair = _changes[(NSUInteger)indexPath.row];
    cell.textLabel.text = pair[0];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = [@"→ " stringByAppendingString:pair[1]];
    cell.detailTextLabel.textColor = UIColor.systemBlueColor;
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)confirmRename
{
    [self.view endEditing:YES];
    NSArray<NSArray<NSString *> *> *changes = [_changes copy];
    if (!changes.count) return;
    __weak typeof(self) weakSelf = self;
    UIAlertController *alert = wq_alert_controller(@"Rename these items?",
        WQLocalizedFormat(@"%lu items in this folder get a new name. Items whose new name already exists are skipped.", (unsigned long)changes.count),
        UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Rename", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [weakSelf performRename:changes];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performRename:(NSArray<NSArray<NSString *> *> *)changes
{
    NSString *folder = _folder;
    NSSet<NSString *> *existing = [NSSet setWithArray:_names];
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSUInteger renamed = 0, skipped = 0;
        NSMutableSet<NSString *> *taken = [existing mutableCopy];
        for (NSArray<NSString *> *pair in changes) {
            if ([taken containsObject:pair[1]]) { skipped++; continue; }
            NSString *error = nil;
            if (wq_rename([folder stringByAppendingPathComponent:pair[0]], pair[1], &error)) {
                renamed++;
                [taken removeObject:pair[0]];
                [taken addObject:pair[1]];
            } else {
                skipped++;
                wq_log(@"bulk rename: %@ -> %@: %@", pair[0], pair[1], error ?: @"failed");
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *text = WQLocalizedFormat(@"%lu renamed, %lu skipped.", (unsigned long)renamed, (unsigned long)skipped);
            UIAlertController *done = wq_alert_controller(@"Bulk Rename", WQVerbatim(text), UIAlertControllerStyleAlert);
            [done addAction:wq_alert_action(@"OK", UIAlertActionStyleCancel, ^(UIAlertAction *__unused a) {
                [strongSelf.navigationController popViewControllerAnimated:YES];
            })];
            [strongSelf presentViewController:done animated:YES completion:nil];
        });
    });
}

@end

#pragma mark - Folder tools menu

UIMenu *wq_folder_tools_menu(UIViewController *host, NSString *path, BOOL readOnly)
{
    __weak UIViewController *weakHost = host;
    NSString *folder = [path copy];
    void (^push)(UIViewController *) = ^(UIViewController *vc) { [weakHost.navigationController pushViewController:vc animated:YES]; };
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray new];

    [items addObject:[UIAction actionWithTitle:WQLocalized(@"Storage Breakdown") image:[UIImage systemImageNamed:@"chart.pie"] identifier:nil
                                       handler:^(UIAction *__unused a) {
        push([[WQToolResultsViewController alloc] initWithTitle:@"Storage Breakdown" readOnly:readOnly work:^NSArray<NSDictionary *> *(WQScanCancellation *c, void (^status)(NSString *)) {
            return wq_ft_storage(folder, c, status);
        }]);
    }]];
    [items addObject:[UIAction actionWithTitle:WQLocalized(@"Find Duplicates") image:[UIImage systemImageNamed:@"square.on.square"] identifier:nil
                                       handler:^(UIAction *__unused a) {
        push([[WQToolResultsViewController alloc] initWithTitle:@"Duplicates" readOnly:readOnly work:^NSArray<NSDictionary *> *(WQScanCancellation *c, void (^status)(NSString *)) {
            return wq_ft_duplicates(folder, c, status);
        }]);
    }]];
    [items addObject:[UIAction actionWithTitle:WQLocalized(@"Find Old Files…") image:[UIImage systemImageNamed:@"clock.badge.exclamationmark"] identifier:nil
                                       handler:^(UIAction *__unused a) {
        UIViewController *strongHost = weakHost;
        if (!strongHost) return;
        UIAlertController *alert = wq_alert_controller(@"Find Old Files", @"Files not changed for at least this many days:", UIAlertControllerStyleAlert);
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.text = @"90";
            field.keyboardType = UIKeyboardTypeNumberPad;
        }];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
        [alert addAction:wq_alert_action(@"Search", UIAlertActionStyleDefault, ^(UIAlertAction *__unused b) {
            NSInteger days = weakAlert.textFields.firstObject.text.integerValue;
            if (days < 1) days = 1;
            push([[WQToolResultsViewController alloc] initWithTitle:@"Old Files" readOnly:readOnly work:^NSArray<NSDictionary *> *(WQScanCancellation *c, void (^status)(NSString *)) {
                return wq_ft_old_files(folder, days, c, status);
            }]);
        })];
        [strongHost presentViewController:alert animated:YES completion:nil];
    }]];

    NSMutableArray<UIMenuElement *> *compare = [NSMutableArray new];
    [compare addObject:[UIAction actionWithTitle:WQLocalized(@"Mark This Folder") image:[UIImage systemImageNamed:@"mappin"] identifier:nil
                                         handler:^(UIAction *__unused a) { sMarkedFolder = [folder copy]; }]];
    if (sMarkedFolder.length && ![sMarkedFolder isEqualToString:folder]) {
        NSString *marked = [sMarkedFolder copy];
        [compare addObject:[UIAction actionWithTitle:WQLocalizedFormat(@"Compare With “%@”", marked.lastPathComponent)
                                               image:[UIImage systemImageNamed:@"arrow.left.arrow.right"] identifier:nil
                                             handler:^(UIAction *__unused a) {
            push([[WQToolResultsViewController alloc] initWithTitle:@"Compare Folders" readOnly:readOnly work:^NSArray<NSDictionary *> *(WQScanCancellation *c, void (^status)(NSString *)) {
                return wq_ft_compare(marked, folder, c, status);
            }]);
        }]];
    }
    [items addObject:[UIMenu menuWithTitle:WQLocalized(@"Compare Folders") image:[UIImage systemImageNamed:@"arrow.left.arrow.right"] identifier:nil options:0 children:compare]];

    if (!readOnly) {
        [items addObject:[UIAction actionWithTitle:WQLocalized(@"Bulk Rename…") image:[UIImage systemImageNamed:@"pencil.line"] identifier:nil
                                           handler:^(UIAction *__unused a) {
            push([[WQBulkRenameViewController alloc] initWithFolder:folder]);
        }]];
    }
    [items addObject:[UIAction actionWithTitle:WQLocalized(@"Tagged Items") image:[UIImage systemImageNamed:@"tag"] identifier:nil
                                       handler:^(UIAction *__unused a) {
        push([[WQToolResultsViewController alloc] initWithTitle:@"Tagged Items" readOnly:readOnly work:^NSArray<NSDictionary *> *(WQScanCancellation *c, void (^status)(NSString *)) {
            (void)c; (void)status;
            return wq_ft_tagged_items();
        }]);
    }]];
    return [UIMenu menuWithTitle:WQLocalized(@"Folder Tools") image:[UIImage systemImageNamed:@"wrench.and.screwdriver"] identifier:nil options:0 children:items];
}

#pragma mark - Backup retention

@implementation WQBackupRetentionViewController {
    NSArray<NSDictionary *> *_apps;   // bundleID, backups (paths, newest first)
}

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(@"Backup Cleanup");
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = [UIColor clearColor];
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:WQLocalized(@"Keep Newest…") style:UIBarButtonItemStylePlain
                                                                              target:self action:@selector(promptKeep)];
    [self reload];
}

- (void)reload
{
    NSString *root = wq_app_backup_root();
    NSMutableArray<NSDictionary *> *apps = [NSMutableArray new];
    for (NSString *bundleID in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        NSString *appDir = [root stringByAppendingPathComponent:bundleID];
        NSMutableArray<NSDictionary *> *backups = [NSMutableArray new];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:appDir error:nil] ?: @[]) {
            if ([name hasPrefix:@"."]) continue;
            NSString *path = [appDir stringByAppendingPathComponent:name];
            struct stat st;
            if (stat(path.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
            NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@".wqbackup.plist"]];
            NSString *reason = [manifest[@"Reason"] isKindOfClass:NSString.class] ? manifest[@"Reason"] : @"";
            [backups addObject:@{@"path": path, @"time": @((long long)st.st_mtime), @"protected": @(reason.length > 0)}];
        }
        if (!backups.count) continue;
        [backups sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"time"] compare:a[@"time"]]; }];
        [apps addObject:@{@"bundleID": bundleID, @"backups": backups}];
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [@([b[@"backups"] count]) compare:@([a[@"backups"] count])];
    }];
    _apps = apps;
    NSUInteger total = 0;
    for (NSDictionary *app in apps) total += [app[@"backups"] count];
    self.navigationItem.prompt = WQLocalizedFormat(@"%lu backups of %lu apps", (unsigned long)total, (unsigned long)apps.count);
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return (NSInteger)_apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"bk"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"bk"];
    NSDictionary *app = _apps[(NSUInteger)indexPath.row];
    NSArray *backups = app[@"backups"];
    cell.textLabel.text = app[@"bundleID"];
    cell.detailTextLabel.text = WQLocalizedFormat(@"%lu backups", (unsigned long)backups.count);
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = wq_app_icon(app[@"bundleID"]);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)promptKeep
{
    if (wq_refuse_if_deleting_off(self)) return;
    UIAlertController *alert = wq_alert_controller(@"Keep Newest Backups", @"Keep this many of the newest backups of every app and delete the older ones. Safety backups made before a restore are always kept.", UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = @"3";
        field.keyboardType = UIKeyboardTypeNumberPad;
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Continue", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSInteger keep = weakAlert.textFields.firstObject.text.integerValue;
        if (keep < 1) keep = 1;
        [weakSelf confirmKeep:(NSUInteger)keep];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSArray<NSString *> *)pathsToDeleteKeeping:(NSUInteger)keep
{
    NSMutableArray<NSString *> *doomed = [NSMutableArray new];
    for (NSDictionary *app in _apps) {
        NSUInteger kept = 0;
        for (NSDictionary *backup in app[@"backups"]) {
            if ([backup[@"protected"] boolValue]) continue;
            if (kept < keep) { kept++; continue; }
            [doomed addObject:backup[@"path"]];
        }
    }
    return doomed;
}

- (void)confirmKeep:(NSUInteger)keep
{
    NSArray<NSString *> *doomed = [self pathsToDeleteKeeping:keep];
    if (!doomed.count) { wq_alert(self, @"Backup Cleanup", @"Nothing to delete: no app has more backups than that."); return; }
    __weak typeof(self) weakSelf = self;
    UIAlertController *alert = wq_alert_controller(@"Delete old backups?",
        WQLocalizedFormat(@"%lu older backups are deleted for good. This can't be undone and they don't go to Recently Deleted.", (unsigned long)doomed.count),
        UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [alert addAction:wq_alert_action(@"Delete", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        if (!wq_deleting_allowed()) return;
        dispatch_async(wq_io(), ^{
            NSUInteger deleted = 0;
            for (NSString *path in doomed) {
                NSString *error = nil;
                if (wq_backup_unit_deletable(path) && wq_delete_backup(path, &error)) deleted++;
                else wq_log(@"backup cleanup: %@: %@", path, error ?: @"not deletable");
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf reload];
                wq_alert(strongSelf, @"Backup Cleanup", WQVerbatim(WQLocalizedFormat(@"%lu backups deleted.", (unsigned long)deleted)));
            });
        });
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - App info

static uint32_t wq_ft_be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static uint32_t wq_ft_le32(const uint8_t *p) { return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0]; }

// Reads the executable's encryption flag and signed entitlements (read only).
static void wq_ft_macho_info(NSString *executable, NSDictionary **entitlements, int *cryptid)
{
    *entitlements = nil;
    *cryptid = -1;
    int fd = wq_open_for_reading(executable);
    if (fd < 0) return;
    uint8_t head[4096];
    ssize_t got = pread(fd, head, sizeof head, 0);
    off_t base = 0;
    if (got >= 8 && wq_ft_be32(head) == 0xCAFEBABE) {
        uint32_t count = wq_ft_be32(head + 4);
        base = -1;
        for (uint32_t i = 0; i < count && i < 16 && 8 + (i + 1) * 20 <= (uint32_t)got; i++) {
            const uint8_t *arch = head + 8 + i * 20;
            if (wq_ft_be32(arch) == 0x0100000C) { base = (off_t)wq_ft_be32(arch + 8); break; }
        }
        if (base < 0) { close(fd); return; }
        got = pread(fd, head, sizeof head, base);
    }
    uint32_t signatureOffset = 0, signatureSize = 0;
    if (got >= 32 && wq_ft_le32(head) == 0xFEEDFACF) {
        uint32_t commands = wq_ft_le32(head + 16), size = wq_ft_le32(head + 20);
        if (commands <= 4096 && size <= 1024 * 1024) {
            uint8_t *lc = malloc(size ? size : 1);
            if (lc && pread(fd, lc, size, base + 32) == (ssize_t)size) {
                uint32_t pos = 0;
                for (uint32_t i = 0; i < commands; i++) {
                    if (pos + 8 > size) break;
                    uint32_t cmd = wq_ft_le32(lc + pos), cmdsize = wq_ft_le32(lc + pos + 4);
                    if (cmdsize < 8 || pos + cmdsize > size) break;
                    if ((cmd == 0x2C || cmd == 0x21) && cmdsize >= 20) *cryptid = wq_ft_le32(lc + pos + 16) != 0 ? 1 : 0;
                    if (cmd == 0x1D && cmdsize >= 16) { signatureOffset = wq_ft_le32(lc + pos + 8); signatureSize = wq_ft_le32(lc + pos + 12); }
                    pos += cmdsize;
                }
            }
            free(lc);
        }
    }
    if (signatureSize >= 12 && signatureSize <= 8 * 1024 * 1024) {
        uint8_t *blob = malloc(signatureSize);
        if (blob && pread(fd, blob, signatureSize, base + signatureOffset) == (ssize_t)signatureSize && wq_ft_be32(blob) == 0xFADE0CC0) {
            uint32_t count = wq_ft_be32(blob + 8);
            for (uint32_t i = 0; i < count && 12 + (i + 1) * 8 <= signatureSize; i++) {
                uint32_t type = wq_ft_be32(blob + 12 + i * 8), offset = wq_ft_be32(blob + 16 + i * 8);
                if (type != 5 || offset + 8 > signatureSize || wq_ft_be32(blob + offset) != 0xFADE7171) continue;
                uint32_t length = wq_ft_be32(blob + offset + 4);
                if (length <= 8 || offset + length > signatureSize) continue;
                NSData *plist = [NSData dataWithBytes:blob + offset + 8 length:length - 8];
                id parsed = [NSPropertyListSerialization propertyListWithData:plist options:NSPropertyListImmutable format:NULL error:nil];
                if ([parsed isKindOfClass:NSDictionary.class]) *entitlements = parsed;
                break;
            }
        }
        free(blob);
    }
    close(fd);
}

static NSString *wq_ft_describe(id value)
{
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value description];
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray new];
        for (id item in value) [parts addObject:wq_ft_describe(item)];
        return [parts componentsJoinedByString:@", "];
    }
    return [value description];
}

@implementation WQAppInfoViewController {
    NSString *_bundleID;
    NSString *_name;
    NSArray<NSDictionary *> *_sections;   // header, rows [[title, value]]
}

- (instancetype)initWithBundleID:(NSString *)bundleID name:(NSString *)name
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _bundleID = [bundleID copy];
        _name = [name copy];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _name.length ? _name : WQLocalizedNullable(@"App Info");
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = [UIColor clearColor];
    }
    self.navigationItem.prompt = WQLocalizedNullable(@"Reading…");
    NSString *bundleID = _bundleID, *name = _name;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *bundlePath = wq_bundle_path_for_id(bundleID);
        NSData *data = bundlePath.length ? wq_read([bundlePath stringByAppendingPathComponent:@"Info.plist"], 1 << 20, NULL) : nil;
        id parsed = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil] : nil;
        NSDictionary *info = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        NSString *executableName = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : nil;
        NSDictionary *entitlements = nil;
        int cryptid = -1;
        if (executableName.length && executableName.pathComponents.count == 1)
            wq_ft_macho_info([bundlePath stringByAppendingPathComponent:executableName], &entitlements, &cryptid);

        NSMutableArray<NSDictionary *> *sections = [NSMutableArray new];
        NSMutableArray<NSArray<NSString *> *> *overview = [NSMutableArray new];
        [overview addObject:@[WQLocalized(@"Name"), name.length ? name : bundleID]];
        [overview addObject:@[WQLocalized(@"Bundle ID"), bundleID]];
        if (info) {
            NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : @"?";
            NSString *build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : @"?";
            [overview addObject:@[WQLocalized(@"Version"), [NSString stringWithFormat:@"%@ (%@)", version, build]]];
            if (info[@"MinimumOSVersion"]) [overview addObject:@[WQLocalized(@"Minimum iOS"), wq_ft_describe(info[@"MinimumOSVersion"])]];
            if (executableName) [overview addObject:@[WQLocalized(@"Executable"), executableName]];
        }
        [overview addObject:@[WQLocalized(@"Encryption"), cryptid == 1 ? WQLocalized(@"Encrypted by Apple (App Store or TestFlight)")
                              : cryptid == 0 ? WQLocalized(@"Not encrypted") : WQLocalized(@"Unknown")]];
        if (bundlePath.length) [overview addObject:@[WQLocalized(@"Bundle folder"), bundlePath]];
        [sections addObject:@{@"header": WQLocalized(@"Overview"), @"rows": overview}];

        if (!info) {
            [sections addObject:@{@"header": WQLocalized(@"Not available"), @"rows": @[@[WQLocalized(@"Info.plist"), WQLocalized(@"This app's files can't be read on this iOS version.")]]}];
        } else {
            NSMutableArray<NSArray<NSString *> *> *schemes = [NSMutableArray new];
            for (NSDictionary *type in [info[@"CFBundleURLTypes"] isKindOfClass:NSArray.class] ? info[@"CFBundleURLTypes"] : @[]) {
                if (![type isKindOfClass:NSDictionary.class]) continue;
                for (id scheme in [type[@"CFBundleURLSchemes"] isKindOfClass:NSArray.class] ? type[@"CFBundleURLSchemes"] : @[])
                    [schemes addObject:@[[NSString stringWithFormat:@"%@://", scheme], [type[@"CFBundleURLName"] isKindOfClass:NSString.class] ? type[@"CFBundleURLName"] : @""]];
            }
            if (schemes.count) [sections addObject:@{@"header": WQLocalized(@"URL Schemes"), @"rows": schemes}];

            NSMutableArray<NSArray<NSString *> *> *permissions = [NSMutableArray new];
            for (NSString *key in [info.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                if ([key hasPrefix:@"NS"] && [key hasSuffix:@"UsageDescription"]) {
                    NSString *shortKey = [key substringWithRange:NSMakeRange(2, key.length - 2 - @"UsageDescription".length)];
                    [permissions addObject:@[shortKey, wq_ft_describe(info[key])]];
                }
            }
            if (permissions.count) [sections addObject:@{@"header": WQLocalized(@"Permissions the app asks for"), @"rows": permissions}];

            if ([info[@"UIBackgroundModes"] isKindOfClass:NSArray.class] && [info[@"UIBackgroundModes"] count])
                [sections addObject:@{@"header": WQLocalized(@"Background Modes"), @"rows": @[@[wq_ft_describe(info[@"UIBackgroundModes"]), @""]]}];
        }
        if (entitlements.count) {
            NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray new];
            for (NSString *key in [entitlements.allKeys sortedArrayUsingSelector:@selector(compare:)])
                [rows addObject:@[key, wq_ft_describe(entitlements[key])]];
            [sections addObject:@{@"header": WQLocalized(@"Entitlements"), @"rows": rows}];
        } else if (info) {
            [sections addObject:@{@"header": WQLocalized(@"Entitlements"), @"rows": @[@[WQLocalized(@"None found"), WQLocalized(@"The executable has no readable signature here.")]]}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_sections = sections;
            strongSelf.navigationItem.prompt = nil;
            [strongSelf.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return (NSInteger)_sections.count; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return (NSInteger)[_sections[(NSUInteger)section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return _sections[(NSUInteger)section][@"header"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"info"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"info"];
    NSArray<NSString *> *row = _sections[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    cell.textLabel.text = row[0];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = row[1];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

// Tap copies the value.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSString *> *row = _sections[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    UIPasteboard.generalPasteboard.string = row[1].length ? row[1] : row[0];
}

@end
