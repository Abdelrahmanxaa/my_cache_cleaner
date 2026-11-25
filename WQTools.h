//
//  WQTools.h
//  WQ Files: version history, IPA library and export-all screens.
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Each installed app's version and build over time. `apps` holds one
// dictionary per app with the keys "bundleID" and "name". Opening the screen
// reads every app's Info.plist, remembers changes, and lists the apps that
// changed since the last time at the top.
@interface WQVersionHistoryViewController : UITableViewController
- (instancetype)initWithApps:(NSArray<NSDictionary<NSString *, NSString *> *> *)apps;
@end

// The IPAs saved in Documents/IPAs: share, delete.
@interface WQIPALibraryViewController : UITableViewController
@end

// Folder tools menu for the folder browser's "…" menu: Storage Breakdown,
// Find Duplicates, Find Old Files, Compare Folders, Bulk Rename, Tagged Items.
// Screens are pushed on host's navigation controller.
UIMenu *wq_folder_tools_menu(UIViewController *host, NSString *path, BOOL readOnly);

// Colored tags kept per path (Application Support/Tags.plist). The marker is a
// colored dot emoji shown before the name, or nil when the path has no tag.
NSString *_Nullable wq_tag_marker(NSString *path);
// A "Tag" submenu for one item; `changed` runs after a tag was set or cleared.
UIMenu *wq_tag_menu(NSString *path, void (^_Nullable changed)(void));

// Defined in main.m: the reasons deleting these paths could harm an app, WQ
// Files or iOS (nil for an ordinary delete).
NSString *_Nullable wq_delete_risk_text(NSArray<NSString *> *paths);

// Per-app backup cleanup: keep only the newest N backups of every app.
@interface WQBackupRetentionViewController : UITableViewController
@end

// A read-only info screen for one installed app: version, build, minimum iOS,
// URL schemes, permission texts, background modes, entitlements, encryption.
@interface WQAppInfoViewController : UITableViewController
- (instancetype)initWithBundleID:(NSString *)bundleID name:(NSString *)name;
@end

// Exports an IPA of every app in `apps` (same dictionaries as above) into
// Documents/IPAs, one after the other, with a progress alert and Cancel.
void wq_export_all_ipas(UIViewController *host, NSArray<NSDictionary<NSString *, NSString *> *> *apps);

// Lets the user tick the apps to export, then exports only those.
void wq_export_selected_ipas(UIViewController *host, NSArray<NSDictionary<NSString *, NSString *> *> *apps);

NS_ASSUME_NONNULL_END
