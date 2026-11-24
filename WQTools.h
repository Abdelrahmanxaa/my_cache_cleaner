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

// Exports an IPA of every app in `apps` (same dictionaries as above) into
// Documents/IPAs, one after the other, with a progress alert and Cancel.
void wq_export_all_ipas(UIViewController *host, NSArray<NSDictionary<NSString *, NSString *> *> *apps);

NS_ASSUME_NONNULL_END
