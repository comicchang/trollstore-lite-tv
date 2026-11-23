// TrollStoreLiteTVDemo —— 最小可用的 tvOS 应用，用来验证「装上去能不能跑」
//
// 它只做一件事：在屏幕上显示自己是怎么被启动的。
// 如果这个界面能出现，说明签名、信任缓存、注册、启动这条链路都通了。

#import <UIKit/UIKit.h>

@interface DemoViewController : UIViewController
@end

@implementation DemoViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"Hello from TrollStore Lite TV";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:56];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectZero];
    sub.text = [NSString stringWithFormat:@"%@ v%@\nbundle: %@",
                info[@"CFBundleName"] ?: @"demo",
                info[@"CFBundleShortVersionString"] ?: @"?",
                info[@"CFBundleIdentifier"] ?: @"?"];
    sub.numberOfLines = 0;
    sub.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    sub.font = [UIFont systemFontOfSize:28];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.text = @"能看到这一屏，说明 ad-hoc 签名 + 内核信任缓存 + 注册都生效了";
    hint.numberOfLines = 0;
    hint.textColor = [UIColor colorWithRed:0.22 green:0.83 blue:0.33 alpha:1.0];
    hint.font = [UIFont systemFontOfSize:24];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:title];
    [self.view addSubview:sub];
    [self.view addSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-90],
        [sub.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:30],
        [hint.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [hint.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:50],
    ]];
}

@end

@interface DemoAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation DemoAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [DemoViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"DemoAppDelegate");
    }
}
