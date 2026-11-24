// TrollStore Lite TV —— tvOS 上的 TrollStore 等价物（GUI 前端）
//
// 架构：GUI 不直接做签名/信任（那是 root 的活），所有动作经 FIFO 交给
//       /usr/libexec/tsltv/tsltvd 执行，再读回响应文件。
//
// 界面：
//   主列表   已安装应用：bundle id、信任✓/✗、注册✓/✗、来源(install/adopt)
//   安装页   输入 ipa 直链 → 下载 → 签名 → 信任 → 注册
//   详情页   cdhash、路径、启动 / 卸载 / 重新校验

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <unistd.h>

// roothide 的 vroot 会把 /var 重定向，所以运行时按候选顺序解析真实目录
static NSString *ATRunDir(void) {
    static NSString *cached = nil;
    if (cached) return cached;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray arrayWithObjects:
        @"/var/run/tsltv",
        @"/private/var/run/tsltv",
        nil];
    // 兜底：扫 jbroot 下的 var/run
    NSString *appBase = @"/var/containers/Bundle/Application";
    for (NSString *e in [fm contentsOfDirectoryAtPath:appBase error:nil]) {
        if (![e hasPrefix:@".jbroot-"]) continue;
        [cands addObject:[NSString stringWithFormat:@"%@/%@/var/run/tsltv", appBase, e]];
    }
    for (NSString *c in cands) {
        if ([fm fileExistsAtPath:[c stringByAppendingPathComponent:@"req.fifo"]]) {
            cached = c;
            return cached;
        }
    }
    if (getenv("TrollStoreLiteTV_SELFTEST")) {
        printf("[debug] 候选目录均无 req.fifo:\n");
        for (NSString *c in cands) {
            printf("  %s  exists=%d\n", c.UTF8String, [fm fileExistsAtPath:c]);
        }
    }
    return cands.firstObject;
}

#pragma mark - daemon 客户端

static NSString *ATRun(NSString *command) {
    NSString *kRunDir = ATRunDir();
    NSString *fifo = [kRunDir stringByAppendingPathComponent:@"req.fifo"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fifo]) {
        return @"错误: tsltvd 未运行（找不到 req.fifo）";
    }
    unsigned long long base = (unsigned long long)(CFAbsoluteTimeGetCurrent() * 1000.0);
    NSString *ident = [NSString stringWithFormat:@"%llu%03u", base, arc4random_uniform(1000)];

    NSString *line = [NSString stringWithFormat:@"%@\t%@\n", ident, command];
    FILE *fp = fopen(fifo.fileSystemRepresentation, "w");
    if (!fp) return @"错误: 无法写入 req.fifo";
    fwrite(line.UTF8String, 1, strlen(line.UTF8String), fp);
    fclose(fp);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *done = [kRunDir stringByAppendingPathComponent:[ident stringByAppendingString:@".done"]];
    NSString *out = [kRunDir stringByAppendingPathComponent:[ident stringByAppendingString:@".out"]];
    NSString *rcf = [kRunDir stringByAppendingPathComponent:[ident stringByAppendingString:@".rc"]];

    // 最长等 180 秒（安装大 ipa 时）
    for (int i = 0; i < 1800; i++) {
        if ([fm fileExistsAtPath:done]) break;
        usleep(100 * 1000);
    }
    if (![fm fileExistsAtPath:done]) {
        [fm removeItemAtPath:out error:nil];
        return @"错误: daemon 超时";
    }
    NSString *text = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:nil] ?: @"";
    [fm removeItemAtPath:out error:nil];
    [fm removeItemAtPath:rcf error:nil];
    [fm removeItemAtPath:done error:nil];
    return text;
}

#pragma mark - 数据模型

@interface ATApp : NSObject
@property (nonatomic, copy) NSString *bid;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *cdhash;
@property (nonatomic, assign) BOOL trusted;
@property (nonatomic, assign) BOOL registered;
@property (nonatomic, copy) NSString *origin;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *version;
@end
@implementation ATApp
@end

// 从 Info.plist 取显示名（二进制 plist 也能读）
static NSString *ATDisplayName(NSString *appPath) {
    NSString *plist = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:plist];
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    NSString *n = d[@"CFBundleDisplayName"] ?: d[@"CFBundleName"];
    return [n isKindOfClass:[NSString class]] && n.length ? n : nil;
}

static NSArray<ATApp *> *ATProbe(void) {
    NSString *out = ATRun(@"probe");
    NSMutableArray<ATApp *> *list = [NSMutableArray array];
    for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
        if (raw.length == 0) continue;
        NSArray *f = [raw componentsSeparatedByString:@"\t"];
        if (f.count < 6) continue;
        ATApp *a = [ATApp new];
        a.bid = f[0];
        a.path = f[1];
        a.cdhash = f[2];
        a.trusted = [f[3] isEqualToString:@"1"];
        a.registered = [f[4] isEqualToString:@"1"];
        a.origin = f[5];
        NSString *nm7 = f.count >= 7 ? (NSString *)f[6] : nil;
        a.version = f.count >= 8 ? (NSString *)f[7] : @"";
        a.name = (nm7.length > 0) ? nm7 : (ATDisplayName(a.path) ?: a.bid);
        [list addObject:a];
    }
    return list;
}

#pragma mark - 主列表

// 电视上必须有非常明确的焦点态：白边 + 轻微放大 + 提亮
@interface ATFocusCell : UITableViewCell
@property (nonatomic, strong) UIView *ring;
@end

@implementation ATFocusCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse {
    if ((self = [super initWithStyle:style reuseIdentifier:reuse])) {
        self.focusStyle = UITableViewCellFocusStyleCustom;
        _ring = [[UIView alloc] initWithFrame:CGRectZero];
        _ring.backgroundColor = [UIColor clearColor];
        _ring.layer.borderColor = [UIColor whiteColor].CGColor;
        _ring.layer.borderWidth = 3;
        _ring.layer.cornerRadius = 10;
        _ring.hidden = YES;
        _ring.userInteractionEnabled = NO;
        [self.contentView addSubview:_ring];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.ring.frame = CGRectInset(self.bounds, 3, 3);
}
- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)ctx withAnimationCoordinator:(UIFocusAnimationCoordinator *)coord {
    [super didUpdateFocusInContext:ctx withAnimationCoordinator:coord];
    BOOL focused = (ctx.nextFocusedView == self);
    [coord addCoordinatedAnimations:^{
        self.ring.hidden = !focused;
        self.contentView.backgroundColor = [UIColor colorWithWhite:(focused ? 0.20 : 0.11) alpha:1.0];
        self.transform = focused ? CGAffineTransformMakeScale(1.02, 1.02) : CGAffineTransformIdentity;
    } completion:nil];
}
@end

@interface ATListController : UITableViewController
@property (nonatomic, strong) NSArray<ATApp *> *apps;
@property (nonatomic, assign) BOOL didSnapshot;
@end

@implementation ATListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TrollStore Lite TV";
    self.tableView.rowHeight = 104;

    // 深色主题：默认白底 + 浅色字在电视上几乎看不见
    UIColor *bg = [UIColor colorWithWhite:0.07 alpha:1.0];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;

    [self buildHeader];
    [self refresh];
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithRed:0.12 green:0.43 blue:0.92 alpha:1.0];
    b.layer.cornerRadius = 10;
    b.contentEdgeInsets = UIEdgeInsetsMake(12, 28, 12, 28);
    [b addTarget:self action:sel forControlEvents:UIControlEventPrimaryActionTriggered];
    return b;
}

// tvOS 不允许改 UINavigationBar 的配色，干脆不用系统导航栏，自己做头部
- (void)buildHeader {
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 150)];
    head.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(60, 30, 500, 60)];
    title.text = @"TrollStore Lite TV";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:44];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(60, 92, 700, 34)];
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    sub.text = [NSString stringWithFormat:@"tvOS 应用安装器 · v%@ · ad-hoc 签名 + 内核信任缓存", ver];
    sub.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    sub.font = [UIFont systemFontOfSize:22];

    UIButton *bRefresh = [self makeButton:@"刷新" action:@selector(refresh)];
    UIButton *bVerify  = [self makeButton:@"校验全部" action:@selector(verifyAll)];
    UIButton *bInstall = [self makeButton:@"安装 IPA" action:@selector(showInstall)];
    UIButton *bInbox   = [self makeButton:@"装目录" action:@selector(installInbox)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[bInstall, bInbox, bVerify, bRefresh]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:title];
    [head addSubview:sub];
    [head addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.trailingAnchor constraintEqualToAnchor:head.trailingAnchor constant:-60],
        [stack.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
    ]];

    self.tableView.tableHeaderView = head;
}

// 自截图：把当前视图树渲染成 PNG，供无显示/无配对环境下核对界面
- (void)snapshotTo:(NSString *)path {
    // tvOS 上 drawViewHierarchyInRect 拿不到画面，直接渲染 CALayer 树
    UIWindow *w = self.view.window ?: UIApplication.sharedApplication.keyWindow;
    UIGraphicsBeginImageContextWithOptions(self.view.bounds.size, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (w.layer) {
        [w.layer renderInContext:ctx];
    } else {
        [self.view.layer renderInContext:ctx];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!img) return;
    NSData *png = UIImagePNGRepresentation(img);
    if (png) [png writeToFile:path atomically:YES];

    // 附带一份状态说明，便于判断"白图"是渲染问题还是没在前台
    NSString *info = [NSString stringWithFormat:
        @"bounds=%.0fx%.0f\nsubviews=%lu\napps=%lu\n"
         @"window=%@ key=%d hidden=%d alpha=%.1f\n"
         @"sceneState=%ld appState=%ld\nrunDir=%@\n",
        self.view.bounds.size.width, self.view.bounds.size.height,
        (unsigned long)self.view.subviews.count, (unsigned long)self.apps.count,
        self.view.window ? @"yes" : @"nil",
        self.view.window.isKeyWindow, self.view.window.isHidden, self.view.window.alpha,
        (long)self.view.window.windowScene.activationState,
        (long)[UIApplication sharedApplication].applicationState,
        ATRunDir()];
    [info writeToFile:@"/var/tmp/tsltv-ui.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 交互自检：存在标记文件时，自动点一次"校验全部"，再截图看弹窗
    BOOL autoRun = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/tmp/tsltv-auto"];
    if (autoRun) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self verifyAll]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(22.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self snapshotTo:@"/var/tmp/tsltv-ui.png"]; });
        return;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/tmp/tsltv-auto-inbox"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self installInbox]; });
    }
    // 截图改到数据加载完成后触发（见 refresh）
}

- (void)refresh {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<ATApp *> *got = ATProbe();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = got;
            [self.tableView reloadData];
            // 数据到齐后再自截图（固定延时可能在加载完成前就拍了）
            if (!self.didSnapshot && got.count > 0) {
                self.didSnapshot = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self snapshotTo:@"/var/tmp/tsltv-ui.png"];
                });
            }
        });
    });
}

- (void)verifyAll {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *out = ATRun(@"verify");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self alert:@"校验结果" body:out];
            [self refresh];
        });
    });
}

// 电视上用遥控器输 URL 很痛苦：把 ipa 放进设备上的投递目录，点一下全装
- (void)installInbox {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *lst = ATRun(@"inbox");
        if ([lst containsString:@"投递目录为空"] || lst.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf alert:@"投递目录是空的"
                           body:@"把 .ipa 传到设备：\n/var/tmp/tsltv-inbox/\n然后回来点这里。"];
            });
            return;
        }
        NSString *out = ATRun(@"inbox-install");
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf alert:@"批量安装结果" body:out];
            [weakSelf refresh];
        });
    });
}

- (void)showInstall {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"安装 IPA"
                                                               message:@"输入 ipa 的直链（http/https）"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"http://example.com/x.ipa";
        tf.keyboardType = UIKeyboardTypeURL;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"下载并安装" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *url = ac.textFields.firstObject.text ?: @"";
        if (url.length == 0) return;
        [weakSelf busy:@"正在下载并安装…"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *out = ATRun([@"install-url " stringByAppendingString:url]);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf dismissBusy];
                [weakSelf alert:@"安装结果" body:out];
                [weakSelf refresh];
            });
        });
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    ATFocusCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) {
        cell = [[ATFocusCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:@"c"];
    }
    ATApp *a = self.apps[ip.row];
    cell.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    cell.contentView.backgroundColor = cell.backgroundColor;
    cell.textLabel.text = a.name.length ? a.name : a.bid;
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:28];
    NSString *vpart = (a.version.length && ![a.version isEqualToString:@"-"]) ? [NSString stringWithFormat:@"v%@  ", a.version] : @"";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@信任%@ 注册%@ %@ %@", a.bid, vpart,
                                 a.trusted ? @"✓" : @"✗",
                                 a.registered ? @"✓" : @"✗",
                                 a.origin,
                                 a.cdhash.length > 12 ? [a.cdhash substringToIndex:12] : a.cdhash];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:20];
    cell.detailTextLabel.textColor = a.trusted ? [UIColor colorWithRed:0.22 green:0.83 blue:0.33 alpha:1]
                                               : [UIColor colorWithRed:0.94 green:0.53 blue:0.24 alpha:1];
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    ATApp *a = self.apps[ip.row];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:a.bid
                                                               message:a.path
                                                        preferredStyle:UIAlertControllerStyleActionSheet];

    [ac addAction:[UIAlertAction actionWithTitle:@"启动" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *x) {
        ATRun([@"launch " stringByAppendingString:a.bid]);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重新信任" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *x) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *out = ATRun(@"trust retrust");
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf alert:@"信任结果" body:out];
                [weakSelf refresh];
            });
        });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"卸载" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *x) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *out = ATRun([@"uninstall " stringByAppendingString:a.bid]);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf alert:@"卸载结果" body:out];
                [weakSelf refresh];
            });
        });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 小工具

- (void)alert:(NSString *)title body:(NSString *)body {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:body
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)busy:(NSString *)text {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:text
                                                               message:@"\n"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    sp.translatesAutoresizingMaskIntoConstraints = NO;
    [ac.view addSubview:sp];
    [NSLayoutConstraint activateConstraints:@[
        [sp.centerXAnchor constraintEqualToAnchor:ac.view.centerXAnchor],
        [sp.bottomAnchor constraintEqualToAnchor:ac.view.bottomAnchor constant:-30],
    ]];
    [sp startAnimating];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)dismissBusy { [self dismissViewControllerAnimated:YES completion:nil]; }

@end

#pragma mark - AppDelegate

@interface ATDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) NSTimer *shotTimer;
@end

@implementation ATDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    ATListController *list = [[ATListController alloc] initWithStyle:UITableViewStylePlain];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];
    nav.navigationBarHidden = YES;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    [@"launched" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"tsltv-launch.txt"]
                  atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // 截图开关：设备上出现 /var/tmp/tsltv-screenshot 就把界面渲染成 PNG 写到
    // /var/tmp/tsltv-shot.png 再退出。用定时轮询而不是只在启动时判断——
    // 应用可能早被 launchd 拉起，事后才创建开关文件。
    self.shotTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:[NSHomeDirectory() stringByAppendingPathComponent:@"shot.flag"]]) return;
        [t invalidate];
        CGSize size = CGSizeMake(1920, 1080);
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            // renderInContext 已经把 UIKit 的坐标系翻好了，这里不能再翻
            UIView *v = self.window.rootViewController.view;
            CGRect b = v.bounds;
            CGContextScaleCTM(ctx.CGContext,
                              size.width / b.size.width, size.height / b.size.height);
            [v.layer renderInContext:ctx.CGContext];
        }];
        NSData *png = UIImagePNGRepresentation(img);
        BOOL ok = [png writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"tsltv-shot.png"] atomically:YES];
        NSLog(@"shot: %@ (%lu bytes)", ok ? @"ok" : @"failed", (unsigned long)png.length);
        [[NSFileManager defaultManager] removeItemAtPath:[NSHomeDirectory() stringByAppendingPathComponent:@"shot.flag"] error:nil];
        if (ok) exit(0);
    }];

    return YES;
}
@end

int main(int argc, char *argv[]) {
    // 无屏幕自检：不做 UI，直接把 GUI 自己的 daemon 客户端跑一遍，
    // 用于在没有显示输出的情况下验证 IPC 通路（遥控器/界面仍需亮屏验证）。
    if (getenv("TrollStoreLiteTV_SELFTEST")) {
        @autoreleasepool {
            printf("== SELFTEST: probe ==\n%s\n", ATRun(@"probe").UTF8String);
            printf("== SELFTEST: verify ==\n%s\n", ATRun(@"verify").UTF8String);
            fflush(stdout);
        }
        return 0;
    }
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"ATDelegate");
    }
}
