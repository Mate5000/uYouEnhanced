#import "Settings.h"
#import "AudioHooks.hpp"
#import <AVFoundation/AVFoundation.h>

static NSUserDefaults *preferences;
static NSBundle *resources;
static ytaeq::Configuration configuration;
ytaeq::Mailbox &YTAEQConfigurationMailbox() {
    // Initialize before publishing restored settings, independent of dylib/C++
    // constructor order. Audio hooks are installed only after this is warmed.
    static ytaeq::Mailbox mailbox;
    return mailbox;
}
ytaeq::Configuration YTAEQCurrentConfiguration() { return configuration; } // main thread only

NSString *YTAEQLocalize(NSString *key) {
    return [resources localizedStringForKey:key value:key table:nil] ?: key;
}
static float savedNumber(NSDictionary *dictionary, NSString *key, float fallback) {
    id value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] ? [value floatValue] : fallback;
}
void YTAEQInitializeSettings() {
    preferences = [[NSUserDefaults alloc] initWithSuiteName:@"com.ytaudioeq.preferences"];
    NSString *path = [NSBundle.mainBundle pathForResource:@"YTAudioEQ" ofType:@"bundle"];
    if (!path) {
        for (NSString *prefix in @[@"/Library/Application Support", @"/var/jb/Library/Application Support"]) {
            NSString *candidate = [prefix stringByAppendingPathComponent:@"YTAudioEQ.bundle"];
            if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) { path = candidate; break; }
        }
    }
    resources = path ? [NSBundle bundleWithPath:path] : nil;
    NSDictionary *saved = [preferences dictionaryForKey:@"configuration"];
    configuration = {};
    configuration.enabled = savedNumber(saved, @"enabled", 0) != 0;
    configuration.bassEnabled = savedNumber(saved, @"bassEnabled", 0) != 0;
    configuration.eqEnabled = savedNumber(saved, @"eqEnabled", 0) != 0;
    configuration.bassFrequency = savedNumber(saved, @"bassFrequency", 80);
    configuration.bassGain = savedNumber(saved, @"bassGain", 4);
    configuration.bassMaxGain = savedNumber(saved, @"bassMaxGain", 12);
    NSArray *bands = saved[@"bands"];
    if ([bands isKindOfClass:NSArray.class] && bands.count == ytaeq::BandCount) {
        for (NSUInteger i = 0; i < bands.count; ++i)
            if ([bands[i] isKindOfClass:NSNumber.class]) configuration.bands[i] = [bands[i] floatValue];
    }
    configuration = ytaeq::sanitize(configuration);
    YTAEQConfigurationMailbox().publish(configuration);
}
void YTAEQSaveConfiguration(ytaeq::Configuration value) {
    NSCAssert(NSThread.isMainThread, @"EQ settings must be serialized on the main thread");
    configuration = ytaeq::sanitize(value);
    NSMutableArray *bands = [NSMutableArray arrayWithCapacity:ytaeq::BandCount];
    for (float gain : configuration.bands) [bands addObject:@(gain)];
    [preferences setObject:@{
        @"enabled": @(configuration.enabled), @"bassEnabled": @(configuration.bassEnabled),
        @"eqEnabled": @(configuration.eqEnabled), @"bassFrequency": @(configuration.bassFrequency),
        @"bassGain": @(configuration.bassGain), @"bassMaxGain": @(configuration.bassMaxGain), @"bands": bands
    } forKey:@"configuration"];
    YTAEQConfigurationMailbox().publish(configuration);
}

static NSString *fourCC(uint32_t value) {
    char code[5] = {};
    for (unsigned i = 0; i < 4; ++i) {
        const char c = char((value >> ((3 - i) * 8)) & 255);
        code[i] = c >= 32 && c <= 126 ? c : '.';
    }
    return [NSString stringWithUTF8String:code];
}
static NSString *errorDescription(uint64_t value) {
    const int32_t status = ytaeq::failureStatus(value);
    return [NSString stringWithFormat:@"%d / 0x%08x / '%@'", status, uint32_t(status), fourCC(uint32_t(status))];
}
NSString *YTAEQAudioDiagnosticReport() {
    const auto &stats = YTAEQAudioStatistics();
    const uint64_t lastFailure = stats.lastFailure.load();
    const auto stage = ytaeq::failureStage(lastFailure);
    NSMutableString *report = [NSMutableString stringWithFormat:@"%@\nYTAudioEQ 1.0.1-diagnostics\n\n", YTAEQLocalize(@"Audio diagnostics")];
    const auto append = ^(NSString *key, id value) { [report appendFormat:@"%@: %@\n", YTAEQLocalize(key), value]; };
    append(@"YouTube version", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?");
    append(@"iOS version", UIDevice.currentDevice.systemVersion);
    append(@"Master / Bass / EQ", [NSString stringWithFormat:@"%d / %d / %d", configuration.enabled, configuration.bassEnabled, configuration.eqEnabled]);
    append(@"Bass frequency / gain / ceiling", [NSString stringWithFormat:@"%.0f Hz / %.1f dB / %.1f dB", configuration.bassFrequency, configuration.bassGain, configuration.bassMaxGain]);
    NSMutableArray *bands = [NSMutableArray array];
    for (float gain : configuration.bands) [bands addObject:[NSString stringWithFormat:@"%+.1f", gain]];
    append(@"EQ bands (dB)", [bands componentsJoinedByString:@", "]);
    [report appendFormat:@"\n%@\n", YTAEQLocalize(@"Last recorded failure (retained after recovery)")];
    append(@"Failure stage", [NSString stringWithUTF8String:ytaeq::failureStageName(stage)]);
    append(@"OSStatus (decimal / hex / FourCC)", errorDescription(lastFailure));
    if (stage == ytaeq::FailureStage::DecoderNeedsInput)
        [report appendFormat:@"%@\n", YTAEQLocalize(@"The decoder requested another compressed packet before producing the expected PCM frames. This is an adapter failure, not proof of an unsupported Bluetooth device. Original audio is preserved.")];
    append(@"Priming configuration status", errorDescription(ytaeq::failureValue(ytaeq::FailureStage::None, stats.primeStatus.load())));
    [report appendFormat:@"\n%@\n", YTAEQLocalize(@"Latest observed audio values")];
    append(@"Source codec / flags", [NSString stringWithFormat:@"'%@' (0x%08x) / 0x%08x", fourCC(stats.formatID.load()), stats.formatID.load(), stats.formatFlags.load()]);
    append(@"Source Hz / channels / bits", [NSString stringWithFormat:@"%u / %u / %u", stats.sourceRate.load(), stats.channels.load(), stats.bitsPerChannel.load()]);
    append(@"Bytes per frame / frames per packet", [NSString stringWithFormat:@"%u / %u", stats.bytesPerFrame.load(), stats.framesPerPacket.load()]);
    append(@"Expected / decoded PCM frames", [NSString stringWithFormat:@"%u / %u", stats.expectedFrames.load(), stats.returnedFrames.load()]);
    append(@"Source samples / frames described by packets", [NSString stringWithFormat:@"%u / %u", stats.sourceSamples.load(), stats.packetFrames.load()]);
    append(@"Available / consumed / requested packets", [NSString stringWithFormat:@"%u / %u / %u", stats.packetCount.load(), stats.consumedPackets.load(), stats.requestedPackets.load()]);
    append(@"Compressed bytes / codec cookie bytes", [NSString stringWithFormat:@"%u / %u", stats.inputBytes.load(), stats.cookieBytes.load()]);
    append(@"Received / compressed / PCM buffers", [NSString stringWithFormat:@"%llu / %llu / %llu", (unsigned long long)stats.receivedBuffers.load(), (unsigned long long)stats.compressedBuffers.load(), (unsigned long long)stats.pcmBuffers.load()]);
    append(@"Processed / failed / bypassed buffers", [NSString stringWithFormat:@"%llu / %llu / %llu", (unsigned long long)stats.processedBlocks.load(), (unsigned long long)stats.unsupportedBlocks.load(), (unsigned long long)stats.bypassedBuffers.load()]);
    append(@"Processed PCM frames", @(stats.processedFrames.load()));
    append(@"Input exhausted / decoder resets / flushes", [NSString stringWithFormat:@"%llu / %llu / %llu", (unsigned long long)stats.inputExhaustions.load(), (unsigned long long)stats.decoderResets.load(), (unsigned long long)stats.flushes.load()]);
    append(@"Sample-buffer hook installed", @(stats.enqueueHookInstalled.load()));
    append(@"RemoteIO hook setup / intercepted starts / callbacks", [NSString stringWithFormat:@"%d / %llu / %llu", stats.remoteHooksInstalled.load(), (unsigned long long)stats.remoteStarts.load(), (unsigned long long)stats.remoteCallbacks.load()]);
    append(@"Import rebinding attempts / images with chained fixups", [NSString stringWithFormat:@"%llu / %llu", (unsigned long long)stats.rebindingAttempts.load(), (unsigned long long)stats.chainedImages.load()]);
    if (stats.chainedImages.load()) [report appendFormat:@"%@\n", YTAEQLocalize(@"Chained fixups were detected. The legacy import rebinder does not confirm access to those Core Audio calls; the callback counters above show what was actually intercepted.")];
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSMutableArray *outputs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *port in session.currentRoute.outputs)
        [outputs addObject:[NSString stringWithFormat:@"%@ (%@)", port.portType, port.portName]];
    append(@"Output route", [outputs componentsJoinedByString:@", "]);
    append(@"Device Hz / IO buffer seconds", [NSString stringWithFormat:@"%.0f / %.4f", session.sampleRate, session.IOBufferDuration]);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    append(@"Adblock Lite / Full / legacy uYou", [NSString stringWithFormat:@"%@ / %@ / %@", [defaults objectForKey:@"adBlockWorkaroundLite_enabled"] ?: @"unset", [defaults objectForKey:@"adBlockWorkaround_enabled"] ?: @"unset", [defaults objectForKey:@"removeYouTubeAds"] ?: @"unset"]);
    [report appendFormat:@"\n%@", YTAEQLocalize(@"Counters are cumulative for this app session. Latest values may come from different streams. Zero processed frames means no EQ effect has been confirmed.")];
    return report;
}

@interface YTAEQDiagnosticsViewController : UIViewController
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) NSTimer *timer;
@end
@implementation YTAEQDiagnosticsViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTAEQLocalize(@"Audio diagnostics");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.textView.adjustsFontForContentSizeCategory = YES;
    self.textView.textColor = UIColor.labelColor;
    self.textView.backgroundColor = UIColor.systemBackgroundColor;
    self.textView.accessibilityIdentifier = @"YTAudioEQ.diagnostics";
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.textContainerInset = UIEdgeInsetsMake(16, 12, 24, 12);
    [self.view addSubview:self.textView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.textView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:YTAEQLocalize(@"Copy diagnostics") style:UIBarButtonItemStylePlain target:self action:@selector(copyDiagnostics)];
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeDiagnostics)];
}
- (void)refreshDiagnostics {
    if (self.textView.selectedRange.length) return;
    CGPoint offset = self.textView.contentOffset;
    self.textView.text = YTAEQAudioDiagnosticReport();
    [self.textView setContentOffset:offset animated:NO];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDiagnostics];
    __weak YTAEQDiagnosticsViewController *weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf refreshDiagnostics]; }];
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self.timer invalidate]; self.timer = nil; }
- (void)copyDiagnostics { UIPasteboard.generalPasteboard.string = YTAEQAudioDiagnosticReport(); }
- (void)closeDiagnostics { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

@interface YTAEQSliderCell : UITableViewCell
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, strong) UISlider *slider;
@end
@implementation YTAEQSliderCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:style reuseIdentifier:identifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _valueLabel = [UILabel new];
    _valueLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _valueLabel.adjustsFontForContentSizeCategory = YES;
    _valueLabel.numberOfLines = 0;
    _slider = [UISlider new];
    _slider.minimumTrackTintColor = [UIColor colorWithRed:0.65 green:0.35 blue:0.85 alpha:1];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_valueLabel, _slider]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:margins.topAnchor constant:4],
        [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-4],
        [_slider.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
    return self;
}
@end

@interface YTAEQViewController : UITableViewController
@property(nonatomic, strong) NSTimer *statusTimer;
@property(nonatomic) uint64_t lastBlocks;
@property(nonatomic) uint64_t lastUnsupported;
@end

@implementation YTAEQViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTAEQLocalize(@"Audio EQ");
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76;
    self.tableView.accessibilityIdentifier = @"YTAudioEQ.panel";
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closePanel)];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    __weak YTAEQViewController *weakSelf = self;
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf updateStatus]; }];
    [self.tableView reloadData];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.statusTimer invalidate]; self.statusTimer = nil;
}
- (void)closePanel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 5; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : section == 1 ? 4 : section == 2 ? 11 : 2;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return YTAEQLocalize(@[@"Audio EQ", @"Bass boost", @"10-band equalizer", @"Reset", @"Diagnostics"][section]);
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return YTAEQLocalize(@"Changes are saved automatically and apply to all videos. Enable Bass boost or Equalizer as well as the master switch.");
    if (section == 1) return YTAEQLocalize(@"A smooth bass shelf. Max gain limits the Bass gain slider; it is not an output volume control.");
    if (section == 2) return YTAEQLocalize(@"Automatic headroom and a -1 dBFS sample-peak limiter protect the digital signal. Some overall volume reduction is normal. AirPlay and Cast are not supported.");
    return nil;
}
- (NSString *)statusText {
    const auto &stats = YTAEQAudioStatistics();
    if (!configuration.enabled) return YTAEQLocalize(@"Off — original audio");
    bool effect = configuration.bassEnabled && configuration.bassGain > 0;
    for (float band : configuration.bands) effect = effect || (configuration.eqEnabled && band != 0);
    if (!effect) return YTAEQLocalize(@"Flat — original audio");
    const uint64_t blocks = stats.processedBlocks.load();
    const uint64_t unsupported = stats.unsupportedBlocks.load();
    NSString *status;
    if (unsupported > self.lastUnsupported || (unsupported && blocks == 0)) {
        const uint64_t value = stats.lastFailure.load();
        status = [NSString stringWithFormat:@"%@\n%s\n%@", YTAEQLocalize(@"Audio processing failed — original audio"), ytaeq::failureStageName(ytaeq::failureStage(value)), errorDescription(value)];
    } else if (blocks > self.lastBlocks) {
        NSString *backend = stats.backend.load() == 1 ? @"AVFoundation" : @"Core Audio";
        status = [NSString stringWithFormat:YTAEQLocalize(@"Active: %@, %u Hz, %llu processed buffers"), backend, stats.sampleRate.load(), (unsigned long long)blocks];
    } else status = YTAEQLocalize(@"Waiting for audio — processing has not been confirmed");
    self.lastBlocks = blocks; self.lastUnsupported = unsupported;
    return status;
}
- (void)updateStatus {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
    NSString *text = [self statusText];
    if (![cell.textLabel.text isEqualToString:text]) {
        cell.textLabel.text = text;
        [UIView performWithoutAnimation:^{ [self.tableView beginUpdates]; [self.tableView endUpdates]; }];
    }
}
- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    const NSInteger section = indexPath.section, row = indexPath.row;
    if ((section == 0 && row == 0) || (section == 1 && row == 0) || (section == 2 && row == 0)) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = YTAEQLocalize(section == 0 ? @"Enable Audio EQ" : section == 1 ? @"Enable bass boost" : @"Enable equalizer");
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.textLabel.numberOfLines = 0;
        UISwitch *toggle = [UISwitch new];
        toggle.tag = section;
        toggle.on = section == 0 ? configuration.enabled : section == 1 ? configuration.bassEnabled : configuration.eqEnabled;
        toggle.accessibilityLabel = cell.textLabel.text;
        toggle.accessibilityIdentifier = [NSString stringWithFormat:@"YTAudioEQ.switch.%ld", (long)section];
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (section == 1 || section == 2) {
        YTAEQSliderCell *cell = [[YTAEQSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        UISlider *slider = cell.slider;
        slider.tag = section == 1 ? row : row + 9;
        slider.minimumValue = section == 1 ? (row == 1 ? 30 : 0) : -12;
        slider.maximumValue = section == 1 ? (row == 1 ? 200 : row == 2 ? MAX(0.01f, configuration.bassMaxGain) : 18) : 12;
        slider.value = section == 1 ? (row == 1 ? configuration.bassFrequency : row == 2 ? configuration.bassGain : configuration.bassMaxGain) : configuration.bands[row - 1];
        slider.enabled = !(section == 1 && row == 2 && configuration.bassMaxGain == 0);
        slider.accessibilityIdentifier = [NSString stringWithFormat:@"YTAudioEQ.slider.%ld", (long)slider.tag];
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self updateSliderLabel:cell];
        return cell;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    if (section == 0) {
        cell.textLabel.text = [self statusText]; cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (section == 4) {
        cell.textLabel.text = YTAEQLocalize(row == 0 ? @"Show detailed diagnostics" : @"Copy diagnostics");
        cell.textLabel.textColor = self.view.tintColor;
        if (row == 0) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = YTAEQLocalize(row == 0 ? @"Reset equalizer to flat" : @"Reset all audio settings");
        cell.textLabel.textColor = self.view.tintColor;
    }
    return cell;
}
- (void)updateSliderLabel:(YTAEQSliderCell *)cell {
    NSInteger tag = cell.slider.tag;
    NSString *name, *value;
    if (tag == 1) { name = YTAEQLocalize(@"Frequency"); value = [NSString stringWithFormat:@"%.0f Hz", configuration.bassFrequency]; }
    else if (tag == 2 || tag == 3) {
        name = YTAEQLocalize(tag == 2 ? @"Bass gain" : @"Max gain");
        value = [NSString stringWithFormat:@"%.1f dB", tag == 2 ? configuration.bassGain : configuration.bassMaxGain];
    } else {
        NSUInteger band = tag - 10;
        double f = ytaeq::Frequencies[band];
        name = f >= 1000 ? [NSString stringWithFormat:@"%g kHz", f / 1000] : [NSString stringWithFormat:@"%g Hz", f];
        value = [NSString stringWithFormat:@"%+.1f dB", configuration.bands[band]];
    }
    cell.valueLabel.text = [NSString stringWithFormat:@"%@: %@", name, value];
    cell.slider.accessibilityLabel = name; cell.slider.accessibilityValue = value;
}
- (void)toggleChanged:(UISwitch *)toggle {
    auto next = configuration;
    if (toggle.tag == 0) next.enabled = toggle.on;
    else if (toggle.tag == 1) next.bassEnabled = toggle.on;
    else next.eqEnabled = toggle.on;
    YTAEQSaveConfiguration(next); [self updateStatus];
}
- (void)sliderChanged:(UISlider *)slider {
    auto next = configuration;
    float value = roundf(slider.value * (slider.tag == 1 ? 1 : 10)) / (slider.tag == 1 ? 1 : 10);
    if (slider.tag == 1) next.bassFrequency = value;
    else if (slider.tag == 2) next.bassGain = value;
    else if (slider.tag == 3) next.bassMaxGain = value;
    else next.bands[slider.tag - 10] = value;
    YTAEQSaveConfiguration(next);
    UIView *view = slider.superview;
    while (view && ![view isKindOfClass:YTAEQSliderCell.class]) view = view.superview;
    if (view) [self updateSliderLabel:(YTAEQSliderCell *)view];
    if (slider.tag == 3) {
        YTAEQSliderCell *gain = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:1]];
        gain.slider.maximumValue = MAX(0.01f, configuration.bassMaxGain);
        gain.slider.value = configuration.bassGain;
        gain.slider.enabled = configuration.bassMaxGain > 0;
        if (gain) [self updateSliderLabel:gain];
    }
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 4) {
        if (indexPath.row == 0) {
            UIViewController *diagnostics = [YTAEQDiagnosticsViewController new];
            if (self.navigationController) [self.navigationController pushViewController:diagnostics animated:YES];
            else [self presentViewController:[[UINavigationController alloc] initWithRootViewController:diagnostics] animated:YES completion:nil];
        }
        else UIPasteboard.generalPasteboard.string = YTAEQAudioDiagnosticReport();
        return;
    }
    if (indexPath.section != 3) return;
    auto next = configuration;
    if (indexPath.row == 0) next.bands = {};
    else next = {};
    YTAEQSaveConfiguration(next); [tableView reloadData];
}
@end

UIViewController *YTAEQCreatePanel() { return [YTAEQViewController new]; }
void YTAEQPresentPanel(id responder, UIView *sourceView) {
    __weak id weakResponder = responder;
    __weak UIView *weakView = sourceView;
    dispatch_async(dispatch_get_main_queue(), ^{
        id candidate = weakResponder ?: weakView;
        UIViewController *owner = nil;
        for (NSUInteger depth = 0; candidate && depth < 32; ++depth) {
            if ([candidate isKindOfClass:UIViewController.class]) { owner = candidate; break; }
            if ([candidate respondsToSelector:@selector(nextResponder)]) candidate = [candidate nextResponder];
            else break;
        }
        UIWindow *window = weakView.window ?: owner.view.window;
        if (!window) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *item in ((UIWindowScene *)scene).windows) if (item.isKeyWindow) { window = item; break; }
            }
        }
        UIViewController *presenter = window.rootViewController;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        if (!presenter || [presenter isKindOfClass:YTAEQViewController.class] ||
            ([presenter isKindOfClass:UINavigationController.class] && [((UINavigationController *)presenter).topViewController isKindOfClass:YTAEQViewController.class])) return;
        void (^show)(UIViewController *) = ^(UIViewController *host) {
            UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:YTAEQCreatePanel()];
            navigation.modalPresentationStyle = UIModalPresentationPageSheet;
            [host presentViewController:navigation animated:YES completion:nil];
        };
        NSString *name = NSStringFromClass(presenter.class);
        if (presenter.presentingViewController && ([name containsString:@"Sheet"] || [name containsString:@"Menu"])) {
            UIViewController *host = presenter.presentingViewController;
            [presenter dismissViewControllerAnimated:YES completion:^{ show(host); }];
        } else if (presenter.isBeingDismissed && presenter.transitionCoordinator) {
            UIViewController *host = presenter.presentingViewController;
            [presenter.transitionCoordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) { if (host) show(host); }];
        } else show(presenter);
    });
}
