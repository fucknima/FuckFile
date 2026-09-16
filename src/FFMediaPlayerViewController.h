#import <AVKit/AVKit.h>

// Media player for audio/video files: folder playlist with prev/next and
// auto-advance, resume position, external subtitle support (SRT/VTT/ASS) and
// the shared 分享/文件信息/移到回收站 actions. Built on AVPlayerViewController,
// so PiP, AirPlay and fullscreen come from the system.
@interface FFMediaPlayerViewController : AVPlayerViewController

- (instancetype)initWithPath:(NSString *)path;
- (instancetype)init NS_UNAVAILABLE;

@end
