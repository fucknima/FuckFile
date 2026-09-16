#import "FFMediaPlayerViewController.h"

#import "FFFileAssociationService.h"
#import "FFLogger.h"
#import "FFViewerActions.h"

static NSString * const kFFMediaResumeKey = @"FFMediaResumePositions";
static const NSUInteger kFFMediaResumeLimit = 60;
static const NSTimeInterval kFFMediaResumeMinSeconds = 8;
static const NSTimeInterval kFFMediaResumeTailGuard = 10;

#pragma mark - Subtitle cue

@interface FFSubtitleCue : NSObject
@property(nonatomic) NSTimeInterval start;
@property(nonatomic) NSTimeInterval end;
@property(nonatomic, copy) NSString *text;
@end

@implementation FFSubtitleCue
@end

#pragma mark - Player

@interface FFMediaPlayerViewController ()
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, copy) NSArray<NSString *> *mediaPaths;
@property(nonatomic) NSUInteger index;
@property(nonatomic, strong) UILabel *subtitleLabel;
@property(nonatomic, strong) UIBarButtonItem *previousItem;
@property(nonatomic, strong) UIBarButtonItem *nextItem;
@property(nonatomic, strong) NSArray<FFSubtitleCue *> *cues;
@property(nonatomic, strong) NSArray<NSString *> *subtitleFiles;
@property(nonatomic, copy) NSString *activeSubtitlePath;
@property(nonatomic, strong) id timeObserver;
@property(nonatomic, strong) UIBarButtonItem *subtitleItem;
@property(nonatomic, strong) UIBarButtonItem *rotateItem;
@property(nonatomic, strong) UIButton *exitFullscreenButton;
@property(nonatomic) BOOL forcedLandscape;
@end

@implementation FFMediaPlayerViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super init];
    if (self) {
        _filePath = [path copy];
        _mediaPaths = @[];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *sessionError = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback
                 mode:AVAudioSessionModeMoviePlayback options:0 error:&sessionError])
        FFLogTag(@"Media", @"audio session category failed: %@",
            sessionError.localizedDescription ?: @"unknown");
    sessionError = nil;
    if (![session setActive:YES error:&sessionError])
        FFLogTag(@"Media", @"audio session activate failed: %@",
            sessionError.localizedDescription ?: @"unknown");

    [self buildChrome];
    [self buildExitFullscreenButton];
    [self startPlaybackAtPath:self.filePath];
    [self installTimeObserver];
    [self loadSiblings];
    [self loadSubtitlesForMedia:self.filePath];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(itemDidPlayToEnd:) name:AVPlayerItemDidPlayToEndTimeNotification
        object:nil];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self saveResumePosition];
    // 无论 push 还是 pop 都退出全屏，避免下一个页面没有导航栏。
    if (self.forcedLandscape) [self setForcedLandscape:NO];
    if (self.isMovingFromParentViewController) {
        [self.player pause];
        if (self.timeObserver) {
            [self.player removeTimeObserver:self.timeObserver];
            self.timeObserver = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        NSError *error = nil;
        [AVAudioSession.sharedInstance setActive:NO
            withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
        if (error) FFLogTag(@"Media", @"audio session deactivate failed: %@",
            error.localizedDescription ?: @"unknown");
    }
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate { return YES; }

// 横屏即全屏：隐藏导航栏、底部标签栏与状态栏，只留视频与退出按钮。
- (BOOL)prefersStatusBarHidden { return self.forcedLandscape; }

- (BOOL)prefersHomeIndicatorAutoHidden { return self.forcedLandscape; }

- (void)buildExitFullscreenButton
{
    UIButton *exit = [UIButton buttonWithType:UIButtonTypeSystem];
    [exit setImage:[UIImage systemImageNamed:@"arrow.down.right.and.arrow.up.left"]
          forState:UIControlStateNormal];
    exit.tintColor = UIColor.whiteColor;
    exit.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    exit.layer.cornerRadius = 18;
    exit.hidden = YES;
    exit.accessibilityLabel = @"退出全屏";
    exit.translatesAutoresizingMaskIntoConstraints = NO;
    [exit addTarget:self action:@selector(exitFullscreenTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:exit];
    [NSLayoutConstraint activateConstraints:@[
        [exit.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [exit.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
            constant:-16],
        [exit.widthAnchor constraintEqualToConstant:36],
        [exit.heightAnchor constraintEqualToConstant:36],
    ]];
    self.exitFullscreenButton = exit;
}

- (void)updateFullscreenChrome
{
    BOOL fullscreen = self.forcedLandscape;
    self.navigationController.navigationBarHidden = fullscreen;
    self.tabBarController.tabBar.hidden = fullscreen;
    self.exitFullscreenButton.hidden = !fullscreen;
    if (fullscreen) [self.view bringSubviewToFront:self.exitFullscreenButton];
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}

- (void)exitFullscreenTapped
{
    [self setForcedLandscape:NO];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

// 播放器里提供一键横屏：锁屏方向打开时系统可能拒绝，如实提示。
- (void)toggleLandscape
{
    [self setForcedLandscape:!self.forcedLandscape];
}

- (void)setForcedLandscape:(BOOL)landscape
{
    // 必须写 ivar：属性自定义 setter 里再赋值会无限递归。
    _forcedLandscape = landscape;
    [self updateRotateItem];
    [self updateFullscreenChrome];
    // 只请求「右转横屏」（UIInterfaceOrientationLandscapeRight），
    // 不用双值 mask：否则系统可能挑到反方向。
    [self requestOrientation:landscape ? UIInterfaceOrientationMaskLandscapeRight
                                       : UIInterfaceOrientationMaskPortrait];
}

- (void)updateRotateItem
{
    self.rotateItem.image = [UIImage systemImageNamed:
        self.forcedLandscape ? @"rotate.left" : @"rotate.right"];
    self.rotateItem.accessibilityLabel = self.forcedLandscape ? @"恢复竖屏" : @"横屏（右转）";
}

- (void)requestOrientation:(UIInterfaceOrientationMask)mask
{
    UIWindowScene *scene = self.view.window.windowScene;
    if (!scene) {
        [UIViewController attemptRotationToDeviceOrientation];
        return;
    }
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *preferences =
            [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
        __weak typeof(self) weakSelf = self;
        [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
            if (!error) return;
            FFLogTag(@"Media", @"orientation request failed: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf flash:@"系统未允许旋转：请关闭控制中心的方向锁定后重试"];
            });
        }];
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
    } else {
        [UIViewController attemptRotationToDeviceOrientation];
    }
}

#pragma mark - Chrome

- (void)buildChrome
{
    UIBarButtonItem *actions = [FFViewerActions actionsItemForPath:self.filePath
        title:nil icon:nil presenter:self allowTrash:YES];
    self.subtitleItem = [[UIBarButtonItem alloc] initWithImage:
        [UIImage systemImageNamed:@"captions.bubble"] menu:[self subtitleMenu]];
    self.rotateItem = [[UIBarButtonItem alloc] initWithImage:
        [UIImage systemImageNamed:@"rotate.right"]
        style:UIBarButtonItemStylePlain target:self action:@selector(toggleLandscape)];
    self.navigationItem.rightBarButtonItems = @[actions, self.subtitleItem, self.rotateItem];

    // 播放器自带底部控制条，播放列表按钮放导航栏左侧并保留返回键。
    self.previousItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"backward.end.fill"]
        style:UIBarButtonItemStylePlain target:self action:@selector(playPrevious)];
    self.nextItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"forward.end.fill"]
        style:UIBarButtonItemStylePlain target:self action:@selector(playNext)];
    self.navigationItem.leftItemsSupplementBackButton = YES;
    self.navigationItem.leftBarButtonItems = @[ self.previousItem, self.nextItem ];

    UILabel *subtitles = [UILabel new];
    subtitles.numberOfLines = 0;
    subtitles.textAlignment = NSTextAlignmentCenter;
    subtitles.textColor = UIColor.whiteColor;
    subtitles.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    subtitles.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    subtitles.layer.cornerRadius = 6;
    subtitles.layer.masksToBounds = YES;
    subtitles.hidden = YES;
    subtitles.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *overlay = self.contentOverlayView;
    if (overlay) {
        [overlay addSubview:subtitles];
        [NSLayoutConstraint activateConstraints:@[
            [subtitles.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
            [subtitles.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor constant:-90],
            [subtitles.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor
                constant:16],
            [subtitles.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor
                constant:-16],
        ]];
    }
    self.subtitleLabel = subtitles;
    [self updateNavigation];
}

- (void)updateNavigation
{
    BOOL multi = self.mediaPaths.count > 1;
    self.previousItem.enabled = multi && self.index > 0;
    self.nextItem.enabled = multi && self.index + 1 < self.mediaPaths.count;
    NSString *name = self.filePath.lastPathComponent ?: @"媒体";
    self.title = multi
        ? [NSString stringWithFormat:@"%@ · %lu/%lu", name,
            (unsigned long)(self.index + 1), (unsigned long)self.mediaPaths.count]
        : name;
}

#pragma mark - Playlist

- (void)loadSiblings
{
    NSString *startingPath = self.filePath;
    NSString *directory = startingPath.stringByDeletingLastPathComponent;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSArray<NSString *> *names = [[manager contentsOfDirectoryAtPath:directory error:nil] ?: @[]
            sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        NSMutableArray<NSString *> *media = [NSMutableArray array];
        for (NSString *name in names) {
            if ([name hasPrefix:@"."]) continue;
            NSString *full = [directory stringByAppendingPathComponent:name];
            BOOL isDirectory = NO;
            if (![manager fileExistsAtPath:full isDirectory:&isDirectory] || isDirectory) continue;
            NSString *viewerID = [FFFileAssociationService
                builtinViewerIDForExtension:name.pathExtension];
            if ([viewerID isEqualToString:@"media"]) [media addObject:full];
        }
        if (![media containsObject:startingPath]) [media insertObject:startingPath atIndex:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.mediaPaths = media;
            NSUInteger index = [media indexOfObject:startingPath];
            strongSelf.index = index == NSNotFound ? 0 : index;
            [strongSelf updateNavigation];
        });
    });
}

- (void)playAtIndex:(NSUInteger)index
{
    if (index >= self.mediaPaths.count) return;
    [self saveResumePosition];
    self.index = index;
    NSString *path = self.mediaPaths[index];
    self.filePath = path;
    self.title = path.lastPathComponent;
    [self loadSubtitlesForMedia:path];
    [self startPlaybackAtPath:path];
    [self updateNavigation];
}

- (void)playPrevious { if (self.index > 0) [self playAtIndex:self.index - 1]; }
- (void)playNext { if (self.index + 1 < self.mediaPaths.count) [self playAtIndex:self.index + 1]; }

- (void)itemDidPlayToEnd:(NSNotification *)note
{
    if (note.object != self.player.currentItem) return;
    [self clearResumePositionForPath:self.filePath];
    if (self.index + 1 < self.mediaPaths.count) [self playAtIndex:self.index + 1];
}

#pragma mark - Playback / resume

- (void)startPlaybackAtPath:(NSString *)path
{
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    if (!self.player) self.player = [AVPlayer playerWithPlayerItem:item];
    else [self.player replaceCurrentItemWithPlayerItem:item];
    NSTimeInterval resume = [self resumePositionForPath:path item:item];
    if (resume > 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                CMTime target = CMTimeMakeWithSeconds(resume, NSEC_PER_SEC);
                [strongSelf.player seekToTime:target toleranceBefore:kCMTimeZero
                    toleranceAfter:kCMTimeZero];
                FFLogTag(@"Media", @"resume at %.0fs path=%@", resume, path.lastPathComponent);
            });
    }
    [self.player play];
}

- (NSDictionary<NSString *, NSDictionary *> *)resumeTable
{
    id stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:kFFMediaResumeKey];
    return [stored isKindOfClass:NSDictionary.class] ? stored : @{};
}

- (NSTimeInterval)resumePositionForPath:(NSString *)path item:(AVPlayerItem *)item
{
    NSDictionary *row = [self resumeTable][path];
    if (![row isKindOfClass:NSDictionary.class]) return 0;
    NSTimeInterval seconds = [row[@"t"] doubleValue];
    if (seconds < kFFMediaResumeMinSeconds) return 0;
    NSTimeInterval duration = item ? CMTimeGetSeconds(item.duration) : 0;
    if (isfinite(duration) && duration > 0 &&
        seconds > duration - kFFMediaResumeTailGuard) return 0;
    return seconds;
}

- (void)saveResumePosition
{
    AVPlayerItem *item = self.player.currentItem;
    if (!item || !self.filePath.length) return;
    NSTimeInterval seconds = CMTimeGetSeconds(item.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(item.duration);
    if (!isfinite(seconds) || seconds < kFFMediaResumeMinSeconds) return;
    if (isfinite(duration) && duration > 0 && seconds > duration - kFFMediaResumeTailGuard) {
        [self clearResumePositionForPath:self.filePath];
        return;
    }
    NSMutableDictionary *table = [[self resumeTable] mutableCopy];
    table[self.filePath] = @{ @"t": @(seconds), @"d": NSDate.date };
    // 有界：超过上限时丢弃最旧的记录。
    if (table.count > kFFMediaResumeLimit) {
        NSArray<NSString *> *sorted = [table.allKeys sortedArrayUsingComparator:
            ^NSComparisonResult(NSString *left, NSString *right) {
                NSDate *leftDate = [table[left] isKindOfClass:NSDictionary.class]
                    ? table[left][@"d"] : nil;
                NSDate *rightDate = [table[right] isKindOfClass:NSDictionary.class]
                    ? table[right][@"d"] : nil;
                return [(NSDate *)leftDate compare:(NSDate *)rightDate];
            }];
        NSUInteger drop = table.count - kFFMediaResumeLimit;
        for (NSUInteger i = 0; i < drop && i < sorted.count; i++) [table removeObjectForKey:sorted[i]];
    }
    [NSUserDefaults.standardUserDefaults setObject:table forKey:kFFMediaResumeKey];
}

- (void)clearResumePositionForPath:(NSString *)path
{
    if (!path.length) return;
    NSMutableDictionary *table = [[self resumeTable] mutableCopy];
    if (!table[path]) return;
    [table removeObjectForKey:path];
    [NSUserDefaults.standardUserDefaults setObject:table forKey:kFFMediaResumeKey];
}

#pragma mark - Subtitles

- (void)loadSubtitlesForMedia:(NSString *)mediaPath
{
    NSString *directory = mediaPath.stringByDeletingLastPathComponent;
    NSString *base = mediaPath.lastPathComponent.stringByDeletingPathExtension;
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    // 约定：同名优先，其次目录内任意 .srt/.vtt/.ass/.ssa。
    for (NSString *extension in @[@"srt", @"vtt", @"ass", @"ssa"]) {
        NSString *sameName = [[directory stringByAppendingPathComponent:base]
            stringByAppendingPathExtension:extension];
        if ([NSFileManager.defaultManager fileExistsAtPath:sameName]) [files addObject:sameName];
    }
    NSArray<NSString *> *names = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        NSString *extension = name.pathExtension.lowercaseString;
        if (![@[@"srt", @"vtt", @"ass", @"ssa"] containsObject:extension]) continue;
        NSString *full = [directory stringByAppendingPathComponent:name];
        if (![files containsObject:full]) [files addObject:full];
    }
    self.subtitleFiles = files;
    self.subtitleItem.menu = [self subtitleMenu];
    // 自动加载第一条与视频同名的字幕，否则保持关闭。
    NSString *autoLoad = nil;
    for (NSString *file in files) {
        if ([file.stringByDeletingPathExtension.lastPathComponent isEqualToString:base]) {
            autoLoad = file;
            break;
        }
    }
    if (autoLoad) {
        [self loadSubtitleFile:autoLoad];
    } else {
        [self clearSubtitles];
    }
}

- (UIMenu *)subtitleMenu
{
    __weak typeof(self) weakSelf = self;
    UIAction *off = [UIAction actionWithTitle:@"关闭" image:nil identifier:@"sub.off"
        handler:^(__unused UIAction *action) { [weakSelf clearSubtitles]; }];
    off.state = self.activeSubtitlePath.length ? UIMenuElementStateOff : UIMenuElementStateOn;
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray arrayWithObject:off];
    for (NSString *file in self.subtitleFiles) {
        UIAction *action = [UIAction actionWithTitle:file.lastPathComponent
            image:nil identifier:file handler:^(__unused UIAction *action) {
                [weakSelf loadSubtitleFile:file];
            }];
        action.state = [self.activeSubtitlePath isEqualToString:file]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:action];
    }
    if (self.subtitleFiles.count == 0) {
        UIAction *none = [UIAction actionWithTitle:@"目录内没有字幕文件" image:nil
            identifier:@"sub.none" handler:nil];
        none.attributes = UIMenuElementAttributesDisabled;
        [items addObject:none];
    }
    return [UIMenu menuWithTitle:@"字幕" children:items];
}

- (void)clearSubtitles
{
    self.cues = @[];
    self.activeSubtitlePath = nil;
    self.subtitleLabel.hidden = YES;
    self.subtitleItem.menu = [self subtitleMenu];
}

- (void)loadSubtitleFile:(NSString *)path
{
    NSError *error = nil;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding
        error:&error];
    if (!text.length) {
        // 常见于 GBK 字幕，退回 Latin-1 至少能显示西文，不乱码崩溃。
        NSData *data = [NSData dataWithContentsOfFile:path];
        text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!text.length) {
            [self flash:[NSString stringWithFormat:@"字幕读取失败：%@",
                error.localizedDescription ?: @"编码不支持"]];
            return;
        }
    }
    NSArray<FFSubtitleCue *> *cues = [self parseSubtitles:text extension:path.pathExtension];
    if (!cues.count) {
        [self flash:@"字幕文件里没有可识别的条目"];
        return;
    }
    self.cues = cues;
    self.activeSubtitlePath = path;
    self.subtitleItem.menu = [self subtitleMenu];
    FFLogTag(@"Media", @"subtitle loaded %@ cues=%lu", path.lastPathComponent,
        (unsigned long)cues.count);
}

// SRT / VTT / ASS 常见形态的宽松解析（不含排版指令）。
- (NSArray<FFSubtitleCue *> *)parseSubtitles:(NSString *)text extension:(NSString *)extension
{
    NSMutableArray<FFSubtitleCue *> *cues = [NSMutableArray array];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:
        [NSCharacterSet newlineCharacterSet]];
    BOOL isASS = [extension.lowercaseString isEqualToString:@"ass"] ||
        [extension.lowercaseString isEqualToString:@"ssa"];

    if (isASS) {
        for (NSString *line in lines) {
            if (![line hasPrefix:@"Dialogue:"]) continue;
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@","];
            if (parts.count < 10) continue;
            NSArray<NSString *> *head = [parts subarrayWithRange:NSMakeRange(0, 10)];
            NSString *body = [[parts subarrayWithRange:NSMakeRange(9, parts.count - 9)]
                componentsJoinedByString:@","];
            FFSubtitleCue *cue = [FFSubtitleCue new];
            cue.start = [self secondsFromASS:head[1]];
            cue.end = [self secondsFromASS:head[2]];
            cue.text = [self cleanSubtitleText:body];
            if (cue.text.length && cue.end > cue.start) [cues addObject:cue];
        }
        return cues;
    }

    NSTimeInterval start = 0, end = 0;
    NSMutableString *body = [NSMutableString string];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet];
        if ([line containsString:@"-->"]) {
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@"-->"];
            start = [self secondsFromTimestamp:parts.firstObject];
            end = parts.count > 1 ? [self secondsFromTimestamp:parts[1]] : 0;
            [body setString:@""];
            continue;
        }
        if (!line.length) {
            if (body.length && end > start) {
                FFSubtitleCue *cue = [FFSubtitleCue new];
                cue.start = start;
                cue.end = end;
                cue.text = [self cleanSubtitleText:body];
                if (cue.text.length) [cues addObject:cue];
            }
            [body setString:@""];
            continue;
        }
        if ([line hasPrefix:@"WEBVTT"] || [line hasPrefix:@"NOTE"] ||
            [line hasPrefix:@"STYLE"]) continue;
        if (body.length) [body appendString:@"\n"];
        [body appendString:line];
    }
    if (body.length && end > start) {
        FFSubtitleCue *cue = [FFSubtitleCue new];
        cue.start = start;
        cue.end = end;
        cue.text = [self cleanSubtitleText:body];
        if (cue.text.length) [cues addObject:cue];
    }
    return cues;
}

- (NSTimeInterval)secondsFromTimestamp:(NSString *)stamp
{
    NSString *value = [stamp stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    value = [value stringByReplacingOccurrencesOfString:@"," withString:@"."];
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@":"];
    if (parts.count < 2) return 0;
    double hours = 0, minutes = 0, seconds = 0;
    if (parts.count >= 3) {
        hours = parts[0].doubleValue;
        minutes = parts[1].doubleValue;
        seconds = parts[2].doubleValue;
    } else {
        minutes = parts[0].doubleValue;
        seconds = parts[1].doubleValue;
    }
    return hours * 3600 + minutes * 60 + seconds;
}

- (NSTimeInterval)secondsFromASS:(NSString *)stamp
{
    return [self secondsFromTimestamp:stamp];   // H:MM:SS.cc，与 SRT 同构
}

- (NSString *)cleanSubtitleText:(NSString *)text
{
    NSMutableString *result = [text mutableCopy];
    // 去 HTML/ASS 标签：<i>、{\pos(…)}、\N 等。
    NSRegularExpression *tags = [NSRegularExpression
        regularExpressionWithPattern:@"<[^>]+>|\\{[^}]*\\}" options:0 error:nil];
    [tags replaceMatchesInString:result options:0
        range:NSMakeRange(0, result.length) withTemplate:@""];
    [result replaceOccurrencesOfString:@"\\N" withString:@"\n" options:0
        range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\\n" withString:@"\n" options:0
        range:NSMakeRange(0, result.length)];
    return [result stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)installTimeObserver
{
    __weak typeof(self) weakSelf = self;
    CMTime interval = CMTimeMakeWithSeconds(0.25, NSEC_PER_SEC);
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:interval
        queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf updateSubtitleForTime:CMTimeGetSeconds(time)];
        }];
}

- (void)updateSubtitleForTime:(NSTimeInterval)seconds
{
    if (!self.cues.count) {
        self.subtitleLabel.hidden = YES;
        return;
    }
    NSString *text = nil;
    for (FFSubtitleCue *cue in self.cues) {
        if (seconds < cue.start) break;
        if (seconds <= cue.end) { text = cue.text; break; }
    }
    self.subtitleLabel.text = text;
    self.subtitleLabel.hidden = text.length == 0;
    // 每次更新都按内容重新排版一次，长句自动换行。
    [self.subtitleLabel.superview setNeedsLayout];
}

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
