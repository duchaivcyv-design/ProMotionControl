// =================================================================================================
// TitaniumBackgroundContinuity.m
// Silent background continuity for the selected server tier.
//
// iOS suspends an app shortly after its background task assertion expires. To keep
// the selected server's timers, rate sentinel and memory guard running, this module
// plays a one-second silent WAV on loop with the public "audio" background mode
// declared in the control app's Info.plist.
//
// Safety:
//  - MixWithOthers keeps other apps' music playing; the session is deactivated with
//    NotifyOthersOnDeactivation when continuity stops.
//  - The loop only runs while the master switch is on, the selected tier is active,
//    that tier's Background Continuity switch is on and the app is backgrounded.
//  - Audio failures are logged and retried a bounded number of times per foreground
//    session; they never throw into the app.
// =================================================================================================
#import "TitaniumBackgroundContinuity.h"
#import "TitaniumServerTierSupport.h"

static AVAudioPlayer *g_TitaniumContinuityPlayer = nil;
static NSInteger g_TitaniumContinuityMode = -1;
static NSInteger g_TitaniumContinuityFailureCount = 0;
static BOOL g_TitaniumContinuitySessionOwned = NO;
static NSString *g_TitaniumContinuityAudioPath = nil;

static const NSInteger kTitaniumContinuityFailureLimit = 5;

static NSString *Titanium_ContinuityKeyForMode(NSInteger mode) {
    if (mode == 2) return @"AdminBackgroundContinuityEnabled";
    if (mode == 1) return @"PremiumBackgroundContinuityEnabled";
    return @"FreeBackgroundContinuityEnabled";
}

static void Titanium_ContinuityAppendLE16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[2] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF) };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void Titanium_ContinuityAppendLE32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[4] = {
        (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF), (uint8_t)((value >> 24) & 0xFF)
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

// 8 kHz, mono, 16-bit PCM, one second of digital silence. The file is tiny and is
// reused for the whole app session.
static NSString *Titanium_ContinuitySilencePath(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"titanium-background-continuity.wav"];
            NSFileManager *manager = [NSFileManager defaultManager];
            if (![manager fileExistsAtPath:path]) {
                const uint32_t sampleRate = 8000;
                const uint32_t dataBytes = sampleRate * 2;
                NSMutableData *wav = [NSMutableData dataWithCapacity:dataBytes + 44];
                [wav appendBytes:"RIFF" length:4];
                Titanium_ContinuityAppendLE32(wav, 36 + dataBytes);
                [wav appendBytes:"WAVE" length:4];
                [wav appendBytes:"fmt " length:4];
                Titanium_ContinuityAppendLE32(wav, 16);
                Titanium_ContinuityAppendLE16(wav, 1);
                Titanium_ContinuityAppendLE16(wav, 1);
                Titanium_ContinuityAppendLE32(wav, sampleRate);
                Titanium_ContinuityAppendLE32(wav, sampleRate * 2);
                Titanium_ContinuityAppendLE16(wav, 2);
                Titanium_ContinuityAppendLE16(wav, 16);
                [wav appendBytes:"data" length:4];
                Titanium_ContinuityAppendLE32(wav, dataBytes);
                [wav increaseLengthBy:dataBytes];
                if (![wav writeToFile:path atomically:YES]) return;
            }
            g_TitaniumContinuityAudioPath = [path copy];
        } @catch (NSException *exception) {
            NSLog(@"[ProMotionControl] Continuity WAV creation failed safely: %@", exception);
        }
    });
    return g_TitaniumContinuityAudioPath;
}

static void Titanium_ContinuityReleaseSession(void) {
    if (g_TitaniumContinuityPlayer) {
        @try {
            [g_TitaniumContinuityPlayer stop];
        } @catch (NSException *exception) {
            NSLog(@"[ProMotionControl] Continuity player stop failed safely: %@", exception);
        }
        g_TitaniumContinuityPlayer = nil;
    }
    g_TitaniumContinuityMode = -1;
    if (!g_TitaniumContinuitySessionOwned) return;
    g_TitaniumContinuitySessionOwned = NO;
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (session) {
            [session setActive:NO
                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                         error:NULL];
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] Continuity session release failed safely: %@", exception);
    }
}

static BOOL Titanium_ContinuityStart(NSInteger mode) {
    NSString *path = Titanium_ContinuitySilencePath();
    if (path.length == 0) return NO;

    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (!session) return NO;
        NSError *error = nil;
        if (![session setCategory:AVAudioSessionCategoryPlayback
                      withOptions:AVAudioSessionCategoryOptionMixWithOthers
                            error:&error]) {
            NSLog(@"[ProMotionControl] Continuity category failed safely: %@", error.localizedDescription);
            return NO;
        }
        if (![session setActive:YES error:&error]) {
            NSLog(@"[ProMotionControl] Continuity activation failed safely: %@", error.localizedDescription);
            return NO;
        }
        g_TitaniumContinuitySessionOwned = YES;

        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                                     error:&error];
        if (!player || ![player prepareToPlay] || ![player play]) {
            NSLog(@"[ProMotionControl] Continuity playback failed safely: %@", error.localizedDescription);
            Titanium_ContinuityReleaseSession();
            return NO;
        }
        player.numberOfLoops = -1;
        player.volume = 0.0;
        g_TitaniumContinuityPlayer = player;
        g_TitaniumContinuityMode = mode;
        NSLog(@"[ProMotionControl] Background continuity active for tier %ld (silent, mixed with other audio).",
              (long)mode);
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] Continuity start failed safely: %@", exception);
        Titanium_ContinuityReleaseSession();
        return NO;
    }
}

BOOL Titanium_BackgroundContinuityRunning(void) {
    return g_TitaniumContinuityPlayer != nil && g_TitaniumContinuityPlayer.isPlaying;
}

void Titanium_BackgroundContinuitySync(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            Titanium_BackgroundContinuitySync();
        });
        return;
    }
    if (!Titanium_TierApplicationReady()) return;

    NSInteger mode = Titanium_CurrentServerMode();
    BOOL wanted = Titanium_TierActive(mode) &&
                  Titanium_ConfigBool(Titanium_ContinuityKeyForMode(mode), YES) &&
                  Titanium_TierIsBackground();

    if (!wanted) {
        if (Titanium_TierIsForeground()) g_TitaniumContinuityFailureCount = 0;
        Titanium_ContinuityReleaseSession();
        return;
    }
    if (g_TitaniumContinuityPlayer && g_TitaniumContinuityPlayer.isPlaying &&
        g_TitaniumContinuityMode == mode) return;
    if (g_TitaniumContinuityFailureCount >= kTitaniumContinuityFailureLimit) return;

    Titanium_ContinuityReleaseSession();
    if (!Titanium_ContinuityStart(mode)) g_TitaniumContinuityFailureCount += 1;
    else g_TitaniumContinuityFailureCount = 0;
}
