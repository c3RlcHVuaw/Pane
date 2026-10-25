#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// NSApplication subclass that satisfies CefAppProtocol. Must be instantiated first.
@interface PCApplication : NSApplication
@end

NS_SWIFT_UI_ACTOR
@protocol PCBrowserDelegate <NSObject>
- (void)browserDidChangeTitle:(NSString *)title;
- (void)browserDidChangeURL:(NSString *)url;
- (void)browserLoadingChanged:(BOOL)loading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)browserDidCreateView:(NSView *)view;
- (void)browserDidChangeFavicon:(NSImage *)image;
- (void)browserRequestsNewTab:(NSString *)url;
- (void)browserAudioChanged:(BOOL)playing;
/// state: 1 = in progress, 2 = complete, 3 = canceled or failed. percent is -1 when unknown.
- (void)browserDownloadUpdated:(uint32_t)downloadID name:(NSString *)name path:(NSString *)path percent:(NSInteger)percent
                      received:(int64_t)received total:(int64_t)total state:(NSInteger)state;
- (void)browserFindResultCount:(NSInteger)count active:(NSInteger)active;
- (void)browserStatusChanged:(NSString *)text;
/// A line the page's Pane script wrote to the console ("__pane:…"); never page content the user wrote.
- (void)browserPageMessage:(NSString *)message;
@optional
/// A page shows alert (0), confirm (1), prompt (2) or a "leave this page?" question (3). Answer through `completion` exactly once.
- (void)browserShowsDialog:(NSInteger)kind origin:(NSString *)origin message:(NSString *)message defaultText:(NSString *)defaultText completion:(void (^)(BOOL ok, NSString *text))completion;
/// A page asks for a permission (camera, microphone, location, clipboard…). `kinds` are plain words such as "camera"; call `decision` once.
- (void)browserRequestsPermission:(NSString *)origin kinds:(NSArray<NSString *> *)kinds decision:(void (^)(BOOL allow))decision;
/// A server asks for a user name and password (HTTP authentication).
- (void)browserRequestsLogin:(NSString *)host realm:(NSString *)realm isProxy:(BOOL)isProxy completion:(void (^)(NSString *_Nullable user, NSString *_Nullable password))completion;
/// The page's certificate is not trusted. Call `proceed(YES)` to continue anyway.
- (void)browserCertificateProblem:(NSString *)url reason:(NSString *)reason proceed:(void (^)(BOOL))proceed;
/// The page entered or left HTML fullscreen (a video, a presentation).
- (void)browserFullscreenChanged:(BOOL)on;
/// The user right-clicked the page. `info` has link, media, selection, editable, misspelled word and suggestions; the app shows its own menu.
- (void)browserShowsContextMenu:(NSDictionary *)info;
/// The page's renderer process died (crash, out of memory or killed).
- (void)browserRenderProcessTerminated:(NSString *)reason;
@end

/// Where a tab keeps its cookies, storage and cache.
NS_SWIFT_UI_ACTOR
@interface PCContext : NSObject
/// Lives only in memory: nothing is written to disk, everything is gone when it is released.
+ (instancetype)privateContext;
/// Persistent and isolated from every other context. `path` must be inside the engine's cache root.
+ (instancetype)contextAtPath:(NSString *)path;
@end

NS_SWIFT_UI_ACTOR
@interface PCBrowser : NSObject
@property (nonatomic, weak, nullable) id<PCBrowserDelegate> delegate;
/// The native view hosting the page; nil until the browser has been created.
@property (nonatomic, readonly, nullable) NSView *view;
- (instancetype)initWithURL:(NSString *)url parent:(NSView *)parent context:(nullable PCContext *)context;
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
/// Tells Chromium the page is not visible so it can throttle rendering.
- (void)setHidden:(BOOL)hidden;
/// Changes the page zoom by `delta` steps (0.5 each); pass 0 to reset.
- (void)zoomBy:(double)delta reset:(BOOL)reset;
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase next:(BOOL)next;
- (void)stopFinding;
/// Current zoom as Chromium's logarithmic level (0 = 100%, each step is 1.2x).
- (double)zoomLevel;
- (void)setMuted:(BOOL)muted;
/// Calls a Chrome DevTools Protocol method on the page (Runtime.evaluate, Input.dispatchMouseEvent, …).
/// `paramsJSON` is a JSON object (or nil). The completion gets the result JSON, or an error description; it is always called once.
- (void)devToolsMethod:(NSString *)method params:(nullable NSString *)paramsJSON
            completion:(void (^)(NSString *_Nullable resultJSON, NSString *_Nullable error))completion;
/// Shows the system print dialog for the page.
- (void)printPage;
- (void)savePDFToPath:(NSString *)path completion:(void (^)(BOOL ok))completion;
/// The visible text of the page's main frame, delivered once on the main thread.
- (void)fetchText:(void (^)(NSString *text))completion;
- (void)cancelDownload:(uint32_t)downloadID;
- (void)close;
/// Closes the page; `completion` runs on the main thread once Chromium has released its view. Keep the parent view alive until then.
- (void)closeWithCompletion:(void (^)(void))completion;
/// Opens Chromium's developer tools for this page in a window of their own.
- (void)showDevTools;
/// Runs an editing command in the focused frame: undo, redo, cut, copy, paste, pasteplain, delete, selectAll.
- (void)performEdit:(NSString *)command;
/// Downloads the file at `url` (the normal download flow runs).
- (void)downloadURL:(NSString *)url;
- (void)replaceMisspelling:(NSString *)word;
- (void)addToDictionary:(NSString *)word;
@end

NS_SWIFT_UI_ACTOR
@interface PCRuntime : NSObject
/// Loads the CEF framework from the main bundle and initializes it. Call once, after NSApp exists.
+ (BOOL)initializeWithCachePath:(NSString *)cachePath;
/// `languages` are BCP-47 codes, most preferred first ("ru-RU", "en-US"): they decide the language of Chromium's own pages and the Accept-Language websites see.
+ (BOOL)initializeWithCachePath:(NSString *)cachePath languages:(NSArray<NSString *> *)languages;
/// Unpacked Chrome extensions to load; set before initializing.
+ (void)setExtensionPaths:(NSArray<NSString *> *)paths;
/// Languages ("ru", "en-US") the spell checker works in; call after initializing.
+ (void)setSpellcheckLanguages:(NSArray<NSString *> *)codes;
+ (void)shutdown;
/// Refuses sub-requests to known ad and tracker hosts. On by default.
+ (void)setAdBlocking:(BOOL)on;
/// A script every page runs before its own scripts (also run once on the page that is already loading).
+ (void)setDocumentStartScript:(NSString *)source;
/// Deletes the cookies a site (a full address) has set.
+ (void)clearCookiesFor:(NSString *)url in:(nullable PCContext *)context completion:(void (^)(void))completion;
/// Deletes cookies and the cache of the default storage (and of `context` when given).
+ (void)clearBrowsingDataIn:(nullable PCContext *)context completion:(void (^)(void))completion;
/// Entry point for helper (renderer/GPU/...) processes. Returns the process exit code.
+ (int)runHelperWithArgc:(int)argc argv:(char *_Nullable *_Nonnull)argv;
@end

NS_ASSUME_NONNULL_END
