#import <AppKit/AppKit.h>
#import <mach-o/dyld.h>

// Electron 32's Squirrel re-executes this exact path after replacement on
// macOS 11+. This helper implements only that launch protocol, never installation.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3 || strcmp(argv[1], "___launch___") != 0) return 64;
        uint32_t size = 0;
        _NSGetExecutablePath(NULL, &size);
        char *path = calloc(size, 1);
        if (path == NULL || _NSGetExecutablePath(path, &size) != 0) return 70;
        NSURL *executable = [NSURL fileURLWithPath:@(path)].URLByResolvingSymlinksInPath;
        free(path);

        // The framework executable is Versions/A/Squirrel. Resources/ShipIt is
        // a relative symlink to it. Derive the enclosing app from our own file.
        NSURL *application = executable;
        for (NSInteger i = 0; i < 6; i++) application = application.URLByDeletingLastPathComponent;
        NSURL *requested = [NSURL fileURLWithPath:@(argv[2])].URLByResolvingSymlinksInPath;
        NSBundle *bundle = [NSBundle bundleWithURL:application];
        if (![application.pathExtension isEqualToString:@"app"] ||
            ![requested.path isEqualToString:application.path] ||
            ![bundle.bundleIdentifier isEqualToString:@"com.electron.parachute"]) return 65;

        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.activates = YES;
        configuration.createsNewApplicationInstance = YES;
        __block BOOL finished = NO;
        __block int result = 1;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:application configuration:configuration
            completionHandler:^(NSRunningApplication *running, NSError *error) {
                if (error != nil || running == nil) {
                    NSLog(@"Parachute migration could not relaunch: %@", error);
                } else {
                    result = 0;
                }
                finished = YES;
            }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
        while (!finished && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        return result;
    }
}
