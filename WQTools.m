//
//  WQTools.m
//  WQ Files: version history, IPA library and export-all screens.
//  GPL-3.0-or-later.
//

#import "WQTools.h"
#import "WQUI.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQHealth.h"
#import "WQArchive.h"
#import <sys/stat.h>

#pragma mark - Shared helpers

// An app bundle's Info.plist, or nil when it can't be read.
static NSDictionary *wq_tools_info_plist(NSString *bundlePath)
{
    if (!bundlePath.length) return nil;
    NSData *data = wq_read([bundlePath stringByAppendingPathComponent:@"Info.plist"], 1 << 20, NULL);
    id parsed = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil] : nil;
    return [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
}

static NSString *wq_tools_string(NSDictionary *info, NSString *key)
{
    id value = info[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

// "1.2.3 (45)", "1.2.3" or "45".
static NSString *wq_tools_version_text(NSString *version, NSString *build)
{
    if (version.length) return build.length ? [NSString stringWithFormat:@"%@ (%@)", version, build] : version;
    return build.length ? build : @"?";
}

static NSString *wq_tools_date_text(NSDate *date)
{
    if (![date isKindOfClass:NSDate.class]) return @"";
    return [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
}

static NSString *wq_tools_safe_name(NSString *text)
{
    NSMutableString *out = [NSMutableString new];
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\n\r\t"];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        [out appendString:[bad characterIsMember:c] ? @"_" : [NSString stringWithCharacters:&c length:1]];
    }
    NSString *trimmed = [out stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ."]];
    return trimmed.length ? trimmed : @"App";
}

// "Documents/IPAs", where Export IPA saves.
static NSString *wq_tools_ipa_folder(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"IPAs"];
}

static NSString *wq_tools_history_file(void)
{
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"VersionHistory.plist"];
}

static void wq_tools_share(UIViewController *host, NSString *path, UIView *source)
{
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    share.popoverPresentationController.sourceView = source ?: host.view;
    share.popoverPresentationController.sourceRect = source ? source.bounds
        : CGRectMake(CGRectGetMidX(host.view.bounds), CGRectGetMidY(host.view.bounds), 1, 1);
    [host presentViewController:share animated:YES completion:nil];
}

#pragma mark - Version history

@implementation WQVersionHistoryViewController {
    NSArray<NSDictionary<NSString *, NSString *> *> *_apps;
    NSArray<NSDictionary *> *_rows;
    BOOL _loading;
}

- (instancetype)initWithApps:(NSArray<NSDictionary<NSString *, NSString *> *> *)apps
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _apps = [apps copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(@"Version History");
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = [UIColor clearColor];
    }
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [self reload];
}

- (void)reload
{
    if (_loading) { [self.refreshControl endRefreshing]; return; }
    _loading = YES;
    self.navigationItem.prompt = WQLocalizedNullable(@"Reading versions…");
    NSArray<NSDictionary<NSString *, NSString *> *> *apps = _apps;
    dispatch_async(wq_io(), ^{
        NSString *file = wq_tools_history_file();
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:file];
        NSMutableDictionary *store = saved ? [saved mutableCopy] : [NSMutableDictionary new];
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
        NSMutableSet<NSString *> *current = [NSMutableSet new];
        NSUInteger changedCount = 0, unreadable = 0;
        for (NSDictionary<NSString *, NSString *> *app in apps) {
            NSString *bundleID = app[@"bundleID"];
            NSString *name = app[@"name"].length ? app[@"name"] : bundleID;
            if (!bundleID.length) continue;
            [current addObject:bundleID];
            NSDictionary *old = [store[bundleID] isKindOfClass:NSDictionary.class] ? store[bundleID] : nil;
            NSMutableArray *entries = [old[@"entries"] isKindOfClass:NSArray.class] ? [old[@"entries"] mutableCopy] : [NSMutableArray new];
            NSDictionary *info = wq_tools_info_plist(wq_bundle_path_for_id(bundleID));
            NSString *previous = nil;
            BOOL changed = NO;
            if (info) {
                NSString *version = wq_tools_string(info, @"CFBundleShortVersionString");
                NSString *build = wq_tools_string(info, @"CFBundleVersion");
                NSDictionary *last = [entries.lastObject isKindOfClass:NSDictionary.class] ? entries.lastObject : nil;
                if (!last || ![last[@"version"] isEqual:version] || ![last[@"build"] isEqual:build]) {
                    if (last) {
                        changed = YES;
                        previous = wq_tools_version_text(last[@"version"], last[@"build"]);
                    }
                    [entries addObject:@{@"version": version, @"build": build, @"date": NSDate.date}];
                }
            } else if (!entries.count) {
                unreadable++;
                continue;
            }
            store[bundleID] = @{@"name": name, @"entries": entries};
            if (changed) changedCount++;
            NSDictionary *last = entries.lastObject;
            [rows addObject:@{@"bundleID": bundleID, @"name": name, @"entries": entries,
                              @"version": last[@"version"] ?: @"", @"build": last[@"build"] ?: @"",
                              @"date": last[@"date"] ?: NSDate.date, @"changed": @(changed),
                              @"previous": previous ?: @"", @"removed": @NO}];
        }
        // Apps that were seen before and are gone now keep their history.
        for (NSString *bundleID in store.allKeys) {
            if ([current containsObject:bundleID]) continue;
            NSDictionary *old = [store[bundleID] isKindOfClass:NSDictionary.class] ? store[bundleID] : nil;
            NSArray *entries = [old[@"entries"] isKindOfClass:NSArray.class] ? old[@"entries"] : nil;
            NSDictionary *last = [entries.lastObject isKindOfClass:NSDictionary.class] ? entries.lastObject : nil;
            if (!last) continue;
            [rows addObject:@{@"bundleID": bundleID, @"name": old[@"name"] ?: bundleID, @"entries": entries,
                              @"version": last[@"version"] ?: @"", @"build": last[@"build"] ?: @"",
                              @"date": last[@"date"] ?: NSDate.date, @"changed": @NO,
                              @"previous": @"", @"removed": @YES}];
        }
        BOOL saved2 = [store writeToFile:file atomically:YES];
        if (!saved2) wq_log(@"version history: could not save %@", file);
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL ca = [a[@"changed"] boolValue], cb = [b[@"changed"] boolValue];
            if (ca != cb) return ca ? NSOrderedAscending : NSOrderedDescending;
            BOOL ra = [a[@"removed"] boolValue], rb = [b[@"removed"] boolValue];
            if (ra != rb) return ra ? NSOrderedDescending : NSOrderedAscending;
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_loading = NO;
            self->_rows = rows;
            if (changedCount) self.navigationItem.prompt = WQLocalizedFormat(@"%lu apps changed version since the last check", (unsigned long)changedCount);
            else if (unreadable == apps.count && apps.count) self.navigationItem.prompt = WQLocalizedNullable(@"Versions can't be read on this iOS version");
            else self.navigationItem.prompt = WQLocalizedNullable(@"No version changes since the last check");
            [self.refreshControl endRefreshing];
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return (NSInteger)_rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ver"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ver"];
    NSDictionary *row = _rows[(NSUInteger)indexPath.row];
    BOOL changed = [row[@"changed"] boolValue], removed = [row[@"removed"] boolValue];
    NSString *now = wq_tools_version_text(row[@"version"], row[@"build"]);
    NSString *detail;
    if (changed) detail = [NSString stringWithFormat:@"%@ → %@", row[@"previous"], now];
    else detail = [NSString stringWithFormat:@"%@ · %@", now, wq_tools_date_text(row[@"date"])];
    if (removed) detail = [NSString stringWithFormat:@"%@ · %@", detail, WQLocalized(@"Not installed")];
    cell.textLabel.text = row[@"name"];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = changed ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.image = wq_app_icon(row[@"bundleID"]);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = _rows[(NSUInteger)indexPath.row];
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (NSDictionary *entry in [row[@"entries"] reverseObjectEnumerator]) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        [lines addObject:[NSString stringWithFormat:@"%@  ·  %@", wq_tools_version_text(entry[@"version"], entry[@"build"]),
                          wq_tools_date_text(entry[@"date"])]];
    }
    NSString *text = [NSString stringWithFormat:@"%@\n\n%@", row[@"bundleID"], [lines componentsJoinedByString:@"\n"]];
    UIAlertController *alert = wq_alert_controller(WQVerbatim(row[@"name"]), WQVerbatim(text), UIAlertControllerStyleAlert);
    NSString *bundleID = row[@"bundleID"];
    [alert addAction:wq_alert_action(@"Copy Bundle ID", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        UIPasteboard.generalPasteboard.string = bundleID;
    })];
    [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleCancel, nil)];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - IPA library

@implementation WQIPALibraryViewController {
    NSArray<NSDictionary *> *_items;
}

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalizedNullable(@"IPA Library");
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = [UIColor clearColor];
    }
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload
{
    NSString *folder = wq_tools_ipa_folder();
    NSMutableArray<NSDictionary *> *items = [NSMutableArray new];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil] ?: @[]) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"ipa"]) continue;
        NSString *path = [folder stringByAppendingPathComponent:name];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        [items addObject:@{@"name": name, @"path": path,
                           @"size": @(attrs.fileSize), @"date": attrs.fileModificationDate ?: [NSDate dateWithTimeIntervalSince1970:0]}];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"date"] compare:a[@"date"]]; }];
    _items = items;
    unsigned long long total = 0;
    for (NSDictionary *item in items) total += [item[@"size"] unsignedLongLongValue];
    self.navigationItem.prompt = items.count
        ? WQLocalizedFormat(@"%lu IPAs · %@", (unsigned long)items.count, wq_size_text(total))
        : nil;
    if (!items.count) {
        UILabel *empty = [UILabel new];
        empty.text = WQLocalizedNullable(@"No IPAs yet. Use Export IPA on an app in Apps.");
        empty.textColor = UIColor.secondaryLabelColor;
        empty.textAlignment = NSTextAlignmentCenter;
        empty.numberOfLines = 0;
        self.tableView.backgroundView = empty;
    } else {
        self.tableView.backgroundView = nil;
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return (NSInteger)_items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ipa"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ipa"];
    NSDictionary *item = _items[(NSUInteger)indexPath.row];
    cell.textLabel.text = item[@"name"];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", wq_size_text([item[@"size"] unsignedLongLongValue]), wq_tools_date_text(item[@"date"])];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    wq_tools_share(self, _items[(NSUInteger)indexPath.row][@"path"], [tableView cellForRowAtIndexPath:indexPath]);
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    if (!wq_deleting_allowed()) return nil;
    NSDictionary *item = _items[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:WQLocalized(@"Delete") handler:^(UIContextualAction *__unused action, UIView *__unused source, void (^done)(BOOL)) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || wq_refuse_if_deleting_off(strongSelf)) { done(NO); return; }
        UIAlertController *alert = wq_alert_controller(@"Delete this IPA?",
            WQVerbatim([NSString stringWithFormat:@"%@\n\n%@", item[@"name"], WQLocalized(@"It is removed from WQ Files and can't be restored. The app itself is not touched.")]),
            UIAlertControllerStyleAlert);
        [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, ^(UIAlertAction *__unused a) { done(NO); })];
        [alert addAction:wq_alert_action(@"Delete", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
            NSError *error = nil;
            BOOL ok = [NSFileManager.defaultManager removeItemAtPath:item[@"path"] error:&error];
            wq_log(@"ipa library: delete %@: %@", item[@"name"], ok ? @"OK" : error.localizedDescription);
            if (!ok) wq_alert(strongSelf, @"Not deleted", WQVerbatim(error.localizedDescription));
            [strongSelf reload];
            done(ok);
        })];
        [strongSelf presentViewController:alert animated:YES completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

@end

#pragma mark - Export all

void wq_export_all_ipas(UIViewController *host, NSArray<NSDictionary<NSString *, NSString *> *> *apps)
{
    if (!wq_app_bundles_reachable() || !wq_display_names_loaded()) {
        wq_alert(host, @"Export IPA", @"This app's files can't be opened on this iOS version, so it can't be exported.");
        return;
    }
    NSMutableArray<NSDictionary *> *todo = [NSMutableArray new];
    for (NSDictionary<NSString *, NSString *> *app in apps) {
        NSString *path = app[@"bundleID"].length ? wq_bundle_path_for_id(app[@"bundleID"]) : nil;
        // Built-in apps live on the system volume, which can't be read.
        if (!path.length || [path hasPrefix:@"/Applications/"] || [path hasPrefix:@"/System/"]) continue;
        [todo addObject:@{@"name": app[@"name"] ?: app[@"bundleID"], @"bundleID": app[@"bundleID"], @"path": path}];
    }
    if (!todo.count) {
        wq_alert(host, @"Export IPA", @"No installed apps can be exported here.");
        return;
    }
    UIAlertController *confirm = wq_alert_controller(@"Export all IPAs?",
        WQLocalizedFormat(@"%lu apps are exported one after another into the IPAs folder. This takes a while and needs free space. Apps from the App Store or TestFlight are exported as they are, still encrypted, and won't launch after re-signing.", (unsigned long)todo.count),
        UIAlertControllerStyleAlert);
    [confirm addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [confirm addAction:wq_alert_action(@"Export", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *folder = wq_tools_ipa_folder();
        NSError *folderError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&folderError]) {
            wq_alert(host, @"Export failed", WQVerbatim(folderError.localizedDescription ?: @"Can't create the IPAs folder"));
            return;
        }
        WQScanCancellation *cancellation = [WQScanCancellation new];
        UIAlertController *hud = wq_alert_controller(@"Exporting IPAs", @"Starting…", UIAlertControllerStyleAlert);
        [hud addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, ^(UIAlertAction *__unused b) { [cancellation cancel]; })];
        [host presentViewController:hud animated:YES completion:nil];
        WQArchiveIO *io = [WQArchiveIO new];
        io.stat = ^BOOL(NSString *path, struct stat *st) { return wq_stat(path, st); };
        io.list = ^NSArray<NSString *> *(NSString *dir) { return wq_list(dir, NULL); };
        io.openRead = ^int(NSString *path) { return wq_open_for_reading(path); };
        dispatch_async(wq_io(), ^{
            NSUInteger saved = 0, index = 0;
            NSMutableArray<NSString *> *failed = [NSMutableArray new];
            for (NSDictionary *app in todo) {
                if (cancellation.isCancelled) break;
                index++;
                NSString *name = app[@"name"], *bundlePath = app[@"path"];
                NSDictionary *info = wq_tools_info_plist(bundlePath);
                NSMutableString *stem = [wq_tools_safe_name(name) mutableCopy];
                NSString *version = wq_tools_string(info, @"CFBundleShortVersionString");
                NSString *build = wq_tools_string(info, @"CFBundleVersion");
                if (version.length) [stem appendFormat:@"_%@", wq_tools_safe_name(version)];
                if (build.length) [stem appendFormat:@"_b%@", wq_tools_safe_name(build)];
                NSString *dest = [folder stringByAppendingPathComponent:[stem stringByAppendingPathExtension:@"ipa"]];
                for (NSUInteger n = 2; [NSFileManager.defaultManager fileExistsAtPath:dest] && n < 1000; n++)
                    dest = [folder stringByAppendingPathComponent:[[NSString stringWithFormat:@"%@ %lu", stem, (unsigned long)n] stringByAppendingPathExtension:@"ipa"]];
                NSString *position = [NSString stringWithFormat:@"%@ (%lu/%lu)", name, (unsigned long)index, (unsigned long)todo.count];
                dispatch_async(dispatch_get_main_queue(), ^{ hud.message = position; });
                __block CFAbsoluteTime lastUpdate = 0;
                WQArchiveProgress progress = ^(unsigned long long bytes) {
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (now - lastUpdate < 0.25) return;
                    lastUpdate = now;
                    NSString *text = [NSString stringWithFormat:@"%@\n%@", position, wq_size_text(bytes)];
                    dispatch_async(dispatch_get_main_queue(), ^{ hud.message = text; });
                };
                NSString *error = nil;
                NSUInteger skipped = 0;
                BOOL ok = wq_zip_write_under(@[bundlePath], @"Payload", dest, io, ^BOOL { return cancellation.isCancelled; }, progress, &skipped, &error);
                wq_log(@"export ipa (all): %@ -> %@: %@", app[@"bundleID"], dest, ok ? @"OK" : (error ?: @"failed"));
                if (ok) saved++;
                else {
                    [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
                    if (!cancellation.isCancelled) [failed addObject:name];
                }
            }
            BOOL wasCancelled = cancellation.isCancelled;
            dispatch_async(dispatch_get_main_queue(), ^{
                void (^finish)(void) = ^{
                    NSMutableString *text = [WQLocalizedFormat(@"%lu IPAs saved in the IPAs folder.", (unsigned long)saved) mutableCopy];
                    if (wasCancelled) [text appendFormat:@"\n%@", WQLocalized(@"Stopped before the end.")];
                    if (failed.count) [text appendFormat:@"\n\n%@\n%@", WQLocalized(@"These failed:"), [failed componentsJoinedByString:@", "]];
                    wq_alert(host, @"Export finished", WQVerbatim(text));
                };
                if (host.presentedViewController == hud) [host dismissViewControllerAnimated:YES completion:finish];
                else finish();
            });
        });
    })];
    [host presentViewController:confirm animated:YES completion:nil];
}
