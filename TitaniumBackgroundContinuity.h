// =================================================================================================
// TitaniumBackgroundContinuity.h
// Keeps the selected server running while the control app lives in the background.
//
// The tweak is injected only into com.dell.promotioncontrol.app, so the only way to
// stay scheduled after the user leaves that app is the public audio background mode:
// a silent, mixed loop that does not interrupt music from other apps. A force-quit
// from the app switcher still terminates the process; nothing inside the app can
// outlive that, because this package ships no LaunchDaemon.
//
// The helper is idempotent and safe to call from a main-queue timer.
// =================================================================================================
#ifndef TitaniumBackgroundContinuity_h
#define TitaniumBackgroundContinuity_h

#import <Foundation/Foundation.h>

// Starts or stops the continuity loop according to the current server mode, the
// master switch and the per-tier Background Continuity switch.
void Titanium_BackgroundContinuitySync(void);

// YES while the silent continuity loop is actually playing.
BOOL Titanium_BackgroundContinuityRunning(void);

#endif /* TitaniumBackgroundContinuity_h */
