#import <UIKit/UIKit.h>

// Share Extension 的可执行入口（MH_EXECUTE）。appex 由 UIKit 启动，
// 类似于应用：提供 main 并由 UIApplicationMain 引导扩展视图控制器。
int main(int argc, char *argv[])
{
    @autoreleasepool {
        // 扩展视图控制器由 NSExtension 机制注册到 UIApplication；这里
        // 复用主流程即可，不需要额外参数。
        return UIApplicationMain(argc, argv, nil, nil);
    }
}
