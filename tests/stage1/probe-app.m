// VerifyProbe —— Stage 2 安装链路用的最小 tvOS App。
// 红底 + 居中文字，装错了也一眼能认出来，卸载无副作用。
#import <UIKit/UIKit.h>

@interface VerifyProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation VerifyProbeAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;

    UIWindow *window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    window.backgroundColor = [UIColor redColor];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = @"com.tsltv.verify.probe\nStage 2 probe — safe to delete";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:48.0];
    [label sizeToFit];
    label.center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    [window addSubview:label];
    [window makeKeyAndVisible];

    self.window = window;
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([VerifyProbeAppDelegate class]));
    }
}