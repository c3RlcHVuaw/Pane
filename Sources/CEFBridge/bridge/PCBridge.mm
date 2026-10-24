#import "CEFBridge.h"

#include <atomic>
#include <string>
#include <map>
#include <set>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_parser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

static CefScopedLibraryLoader *g_loader = nullptr;
static std::set<PCBrowser *> g_browsers;

// MARK: - Message pump

static BOOL g_inPump = NO;
static BOOL g_pumpAgain = NO;
static BOOL g_shutDown = NO;

static void SchedulePump(int64_t delayMs);

/// Runs CEF's work on the main thread, never re-entrantly: a timer firing while CEF is already running
/// (for example inside a nested run loop) crashed the browser process. A request that arrives meanwhile is replayed afterwards.
static void PumpOnce() {
  if (g_shutDown) return;
  if (g_inPump) { g_pumpAgain = YES; return; }
  g_inPump = YES;
  CefDoMessageLoopWork();
  g_inPump = NO;
  if (g_pumpAgain) { g_pumpAgain = NO; SchedulePump(1); }
}

static void SchedulePump(int64_t delayMs) {
  // CEF may ask from any thread; the pump itself only ever runs on the main queue.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, std::max<int64_t>(delayMs, 0) * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{ PumpOnce(); });
}

// MARK: - App

class PCApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnBeforeCommandLineProcessing(const CefString &, CefRefPtr<CefCommandLine> cl) override {
    cl->AppendSwitch("use-mock-keychain");
    // Pages keep running while another window covers Pane (the agent works in the background, downloads and calls continue).
    cl->AppendSwitch("disable-backgrounding-occluded-windows");
    cl->AppendSwitch("disable-renderer-backgrounding");
    cl->AppendSwitch("disable-background-timer-throttling");
  }
  void OnScheduleMessagePumpWork(int64_t delay_ms) override { SchedulePump(delay_ms); }

 private:
  IMPLEMENT_REFCOUNTING(PCApp);
};

// MARK: - Client

@interface PCBrowser ()
- (void)didCreate:(CefRefPtr<CefBrowser>)b;
- (void)devToolsResult:(int)messageID success:(BOOL)ok json:(NSString *)json;
- (void)didClose;
- (void)title:(NSString *)t;
- (void)url:(NSString *)u;
- (void)loading:(BOOL)l back:(BOOL)b fwd:(BOOL)f;
- (void)favicon:(NSImage *)i;
- (void)popup:(NSString *)u;
- (void)audio:(BOOL)on;
- (void)download:(uint32_t)did name:(NSString *)name path:(NSString *)path percent:(NSInteger)pct received:(int64_t)r total:(int64_t)t state:(NSInteger)s;
- (void)found:(NSInteger)count active:(NSInteger)active;
- (void)cancelDownload:(uint32_t)did;
- (void)status:(NSString *)text;
- (void)crashed:(NSString *)reason;
- (void)pageMessage:(NSString *)message;
@end

static NSString *NS(const CefString &s) { return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @""; }

/// A free path in ~/Downloads for `suggested`: no directories, no hidden files, never overwrites ("name (2).ext").
static NSString *UniqueDownloadPath(NSString *suggested) {
  NSString *dir = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
  NSString *name = suggested.lastPathComponent;
  if (name.length == 0 || [name hasPrefix:@"."]) name = @"download";
  NSString *base = name.stringByDeletingPathExtension, *ext = name.pathExtension;
  NSString *path = [dir stringByAppendingPathComponent:name];
  for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:path]; n++) {
    NSString *candidate = ext.length ? [NSString stringWithFormat:@"%@ (%d).%@", base, n, ext] : [NSString stringWithFormat:@"%@ (%d)", base, n];
    path = [dir stringByAppendingPathComponent:candidate];
  }
  return path;
}

class PCIconCallback : public CefDownloadImageCallback {
 public:
  explicit PCIconCallback(PCBrowser *o) : owner_(o) {}
  void OnDownloadImageFinished(const CefString &, int, CefRefPtr<CefImage> image) override {
    if (!image || image->IsEmpty()) return;
    int w = 0, h = 0;
    CefRefPtr<CefBinaryValue> png = image->GetAsPNG(1.0f, true, w, h);
    if (!png) return;
    NSMutableData *d = [NSMutableData dataWithLength:png->GetSize()];
    png->GetData(d.mutableBytes, d.length, 0);
    NSImage *img = [[NSImage alloc] initWithData:d];
    if (img) [owner_ favicon:img];
  }

 private:
  __weak PCBrowser *owner_;
  IMPLEMENT_REFCOUNTING(PCIconCallback);
};

class PCPdfCallback : public CefPdfPrintCallback {
 public:
  explicit PCPdfCallback(void (^block)(BOOL)) : block_(block) {}
  void OnPdfPrintFinished(const CefString &, bool ok) override { block_(ok); }

 private:
  void (^block_)(BOOL);
  IMPLEMENT_REFCOUNTING(PCPdfCallback);
};

class PCDevToolsObserver : public CefDevToolsMessageObserver {
 public:
  explicit PCDevToolsObserver(PCBrowser *owner) : owner_(owner) {}
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id, bool success, const void *result, size_t size) override;

 private:
  __weak PCBrowser *owner_;
  IMPLEMENT_REFCOUNTING(PCDevToolsObserver);
};

class PCTextVisitor : public CefStringVisitor {
 public:
  explicit PCTextVisitor(void (^block)(NSString *)) : block_(block) {}
  void Visit(const CefString &s) override { block_(NS(s)); }

 private:
  void (^block_)(NSString *);
  IMPLEMENT_REFCOUNTING(PCTextVisitor);
};

// MARK: - Content blocking

static std::atomic<bool> g_adBlock{true};

/// Hosts that only serve ads or trackers. Subresources from these (and their subdomains) are refused.
static bool PCIsBlockedHost(const std::string &host) {
  static const char *const kBlocked[] = {
    "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com", "google-analytics.com",
    "googletagservices.com", "pagead2.googlesyndication.com", "2mdn.net", "adnxs.com", "adsrvr.org", "advertising.com",
    "amazon-adsystem.com", "criteo.com", "criteo.net", "outbrain.com", "taboola.com", "rubiconproject.com", "pubmatic.com",
    "openx.net", "casalemedia.com", "moatads.com", "scorecardresearch.com", "quantserve.com", "zedo.com", "smartadserver.com",
    "yieldmo.com", "teads.tv", "adform.net", "bidswitch.net", "contextweb.com", "lijit.com", "sharethrough.com", "media.net",
    "mc.yandex.ru", "an.yandex.ru", "awaps.yandex.net", "adfox.ru", "yandexadexchange.net", "top.mail.ru", "ad.mail.ru",
    "hotjar.com", "mouseflow.com", "fullstory.com", "ads.yahoo.com", "adsystem.com", "serving-sys.com", "popads.net",
    "propellerads.com", "exoclick.com", "juicyads.com", "adsterra.com", "mgid.com", "revcontent.com", "onesignal.com",
    "ads.twitter.com", "analytics.twitter.com", "ads.linkedin.com", "px.ads.linkedin.com", "ads-api.tiktok.com",
    "analytics.tiktok.com", "bat.bing.com", "clarity.ms", "stats.g.doubleclick.net",
  };
  for (const char *d : kBlocked) {
    size_t n = strlen(d);
    if (host.size() == n && host == d) return true;
    if (host.size() > n && host.compare(host.size() - n, n, d) == 0 && host[host.size() - n - 1] == '.') return true;
  }
  return false;
}

class PCClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler, public CefLoadHandler,
                 public CefAudioHandler, public CefDownloadHandler, public CefRequestHandler, public CefFindHandler, public CefResourceRequestHandler {
 public:
  explicit PCClient(PCBrowser *owner) : owner_(owner) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefAudioHandler> GetAudioHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>,
                                                                 bool, bool, const CefString &, bool &) override {
    return this;
  }
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback>) override {
    if (!g_adBlock.load() || request->GetResourceType() == RT_MAIN_FRAME) return RV_CONTINUE;
    CefURLParts parts;
    if (!CefParseURL(request->GetURL(), parts)) return RV_CONTINUE;
    std::string host = CefString(&parts.host).ToString();
    return PCIsBlockedHost(host) ? RV_CANCEL : RV_CONTINUE;
  }

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int, const CefString &) override {
    NSString *why = status == TS_PROCESS_OOM ? @"ran out of memory"
                  : status == TS_PROCESS_WAS_KILLED ? @"was stopped"
                  : @"crashed";
    [owner_ crashed:why];
  }

  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>, const CefString &suggested,
                        CefRefPtr<CefBeforeDownloadCallback> cb) override {
    cb->Continue(UniqueDownloadPath(NS(suggested)).UTF8String, false);
    return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback> cb) override {
    uint32_t id = item->GetId();
    NSInteger state = item->IsComplete() ? 2 : (item->IsInProgress() && !item->IsCanceled()) ? 1 : 3;
    if (state == 1) downloads_[id] = cb; else downloads_.erase(id);
    [owner_ download:id name:NS(item->GetSuggestedFileName()) path:NS(item->GetFullPath()) percent:item->GetPercentComplete()
            received:item->GetReceivedBytes() total:item->GetTotalBytes() state:state];
  }
  void cancelDownload(uint32_t id) {
    auto it = downloads_.find(id);
    if (it != downloads_.end()) it->second->Cancel();
  }

  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  void OnFindResult(CefRefPtr<CefBrowser>, int, int count, const CefRect &, int active, bool) override { [owner_ found:count active:active]; }
  void OnStatusMessage(CefRefPtr<CefBrowser>, const CefString &value) override { [owner_ status:NS(value)]; }

  // Audio callbacks arrive on other threads; hop to main before touching UI state.
  void OnAudioStreamStarted(CefRefPtr<CefBrowser>, const CefAudioParameters &, int) override { post(YES); }
  void OnAudioStreamPacket(CefRefPtr<CefBrowser>, const float **, int, int64_t) override {}
  void OnAudioStreamStopped(CefRefPtr<CefBrowser>) override { post(NO); }
  void OnAudioStreamError(CefRefPtr<CefBrowser>, const CefString &) override { post(NO); }
  void post(BOOL on) {
    __weak PCBrowser *o = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{ [o audio:on]; });
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> b) override { [owner_ didCreate:b]; }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override { [owner_ didClose]; }
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int, const CefString &url,
                     const CefString &, CefLifeSpanHandler::WindowOpenDisposition, bool,
                     const CefPopupFeatures &, CefWindowInfo &, CefRefPtr<CefClient> &, CefBrowserSettings &,
                     CefRefPtr<CefDictionaryValue> &, bool *) override {
    [owner_ popup:NS(url)];
    return true;
  }
  /// Pane's own page scripts talk to the app through the console; those lines are swallowed here.
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t, const CefString &message, const CefString &, int) override {
    NSString *m = NS(message);
    if (![m hasPrefix:@"__pane:"]) return false;
    __weak PCBrowser *o = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{ [o pageMessage:m]; });
    return true;
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &t) override { [owner_ title:NS(t)]; }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> f, const CefString &u) override {
    if (f->IsMain()) [owner_ url:NS(u)];
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser> b, const std::vector<CefString> &urls) override {
    if (urls.empty()) return;
    b->GetHost()->DownloadImage(urls[0], true, 32, false, new PCIconCallback(owner_));
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool l, bool b, bool f) override {
    [owner_ loading:l back:b fwd:f];
  }
  void detach() { owner_ = nil; }

 private:
  __weak PCBrowser *owner_;
  std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> downloads_;
  IMPLEMENT_REFCOUNTING(PCClient);
};

void PCDevToolsObserver::OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id, bool success, const void *result, size_t size) {
  NSString *json = size ? [[NSString alloc] initWithBytes:result length:size encoding:NSUTF8StringEncoding] : @"";
  [owner_ devToolsResult:message_id success:success json:json ?: @""];
}

// MARK: - PCContext

@interface PCContext () {
  CefRefPtr<CefRequestContext> _ctx;
}
- (CefRefPtr<CefRequestContext>)cefContext;
@end

@implementation PCContext
+ (instancetype)privateContext { return [self contextAtPath:@""]; }  // an empty cache path means "memory only"
+ (instancetype)contextAtPath:(NSString *)path {
  PCContext *c = [[PCContext alloc] init];
  CefRequestContextSettings s;
  CefString(&s.cache_path) = path.UTF8String;
  c->_ctx = CefRequestContext::CreateContext(s, nullptr);
  return c;
}
- (CefRefPtr<CefRequestContext>)cefContext { return _ctx; }
@end

// MARK: - PCBrowser

@implementation PCBrowser {
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSMutableDictionary<NSNumber *, void (^)(NSString *, NSString *)> *_devToolsCallbacks;
  CefRefPtr<PCClient> _client;
  NSView *_view;
  BOOL _closeRequested, _created;
  void (^_closeCompletion)(void);
  PCBrowser *_selfRef;
}

- (instancetype)initWithURL:(NSString *)url parent:(NSView *)parent context:(PCContext *)context {
  if ((self = [super init])) {
    g_browsers.insert(self);
    _client = new PCClient(self);
    CefWindowInfo info;
    NSRect b = parent.bounds;
    info.SetAsChild((__bridge CefWindowHandle)parent, CefRect(0, 0, (int)b.size.width, (int)b.size.height));
    CefBrowserSettings settings;
    CefBrowserHost::CreateBrowser(info, _client, url.UTF8String, settings, nullptr, context ? [context cefContext] : nullptr);
  }
  return self;
}

- (NSView *)view { return _view; }

- (void)didCreate:(CefRefPtr<CefBrowser>)b {
  _browser = b;
  _created = YES;
  if (_closeRequested) { b->GetHost()->CloseBrowser(true); return; }  // closed before it finished opening
  _devToolsCallbacks = [NSMutableDictionary dictionary];
  _devToolsRegistration = b->GetHost()->AddDevToolsMessageObserver(new PCDevToolsObserver(self));
  _view = (__bridge NSView *)b->GetHost()->GetWindowHandle();
  _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self.delegate browserDidCreateView:_view];
}
- (void)didClose {
  // Anyone still waiting on the protocol must not wait forever.
  for (NSNumber *k in _devToolsCallbacks.allKeys) { _devToolsCallbacks[k](nil, @"The page was closed."); }
  [_devToolsCallbacks removeAllObjects];
  _devToolsRegistration = nullptr;
  _browser = nullptr;
  g_browsers.erase(self);
  [self finishClose];
}

- (void)dealloc { g_browsers.erase(self); }

- (void)devToolsResult:(int)messageID success:(BOOL)ok json:(NSString *)json {
  void (^cb)(NSString *, NSString *) = _devToolsCallbacks[@(messageID)];
  if (!cb) return;
  [_devToolsCallbacks removeObjectForKey:@(messageID)];
  ok ? cb(json, nil) : cb(nil, json.length ? json : @"The page rejected the request.");
}

- (void)devToolsMethod:(NSString *)method params:(NSString *)paramsJSON completion:(void (^)(NSString *, NSString *))completion {
  if (!_browser) { completion(nil, @"The page isn't ready."); return; }
  CefRefPtr<CefDictionaryValue> params;
  if (paramsJSON.length) {
    CefRefPtr<CefValue> v = CefParseJSON(paramsJSON.UTF8String, JSON_PARSER_RFC);
    if (!v || v->GetType() != VTYPE_DICTIONARY) { completion(nil, @"Bad parameters."); return; }
    params = v->GetDictionary();
  }
  int id = _browser->GetHost()->ExecuteDevToolsMethod(0, method.UTF8String, params);
  if (id == 0) { completion(nil, @"The page couldn't take that request."); return; }
  _devToolsCallbacks[@(id)] = [completion copy];
}
- (void)title:(NSString *)t { [self.delegate browserDidChangeTitle:t]; }
- (void)url:(NSString *)u { [self.delegate browserDidChangeURL:u]; }
- (void)loading:(BOOL)l back:(BOOL)b fwd:(BOOL)f { [self.delegate browserLoadingChanged:l canGoBack:b canGoForward:f]; }

- (void)favicon:(NSImage *)i { [self.delegate browserDidChangeFavicon:i]; }
- (void)popup:(NSString *)u { [self.delegate browserRequestsNewTab:u]; }
- (void)audio:(BOOL)on { [self.delegate browserAudioChanged:on]; }
- (void)download:(uint32_t)did name:(NSString *)name path:(NSString *)path percent:(NSInteger)pct received:(int64_t)r total:(int64_t)t state:(NSInteger)s {
  [self.delegate browserDownloadUpdated:did name:name path:path percent:pct received:r total:t state:s];
}
- (void)found:(NSInteger)count active:(NSInteger)active { [self.delegate browserFindResultCount:count active:active]; }
- (void)cancelDownload:(uint32_t)did { if (_client) _client->cancelDownload(did); }
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase next:(BOOL)next {
  if (_browser) _browser->GetHost()->Find(text.UTF8String, forward, matchCase, next);
}
- (void)stopFinding { if (_browser) _browser->GetHost()->StopFinding(true); }
- (double)zoomLevel { return _browser ? _browser->GetHost()->GetZoomLevel() : 0.0; }
- (void)fetchText:(void (^)(NSString *))completion {
  if (!_browser) { completion(@""); return; }
  _browser->GetMainFrame()->GetText(new PCTextVisitor(completion));
}
- (void)printPage { if (_browser) _browser->GetHost()->Print(); }
- (void)savePDFToPath:(NSString *)path completion:(void (^)(BOOL))completion {
  if (!_browser) { completion(NO); return; }
  CefPdfPrintSettings s;
  s.print_background = true;
  _browser->GetHost()->PrintToPDF(path.UTF8String, s, new PCPdfCallback(completion));
}
- (void)setMuted:(BOOL)muted { if (_browser) _browser->GetHost()->SetAudioMuted(muted); }
- (void)status:(NSString *)text { [self.delegate browserStatusChanged:text]; }
- (void)crashed:(NSString *)reason { [self.delegate browserRenderProcessTerminated:reason]; }
- (void)pageMessage:(NSString *)message { [self.delegate browserPageMessage:message]; }
- (void)zoomBy:(double)delta reset:(BOOL)reset {
  if (!_browser) return;
  CefRefPtr<CefBrowserHost> h = _browser->GetHost();
  h->SetZoomLevel(reset ? 0.0 : std::min(6.0, std::max(-4.0, h->GetZoomLevel() + delta)));
}
- (void)setHidden:(BOOL)hidden { if (_browser) _browser->GetHost()->WasHidden(hidden); }

- (void)loadURL:(NSString *)url { if (_browser) _browser->GetMainFrame()->LoadURL(url.UTF8String); }
- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
- (void)reload { if (_browser) _browser->Reload(); }
- (void)stopLoading { if (_browser) _browser->StopLoad(); }
/// Closes the page and calls `completion` (on the main thread) once Chromium has really let go of its view. Until then this
/// object keeps itself alive, and the caller must keep the parent view alive: tearing either down earlier crashed the browser.
- (void)closeWithCompletion:(void (^)(void))completion {
  if (_closeRequested) { if (completion) completion(); return; }
  _closeRequested = YES;
  _closeCompletion = [completion copy];
  _selfRef = self;
  if (_browser) _browser->GetHost()->CloseBrowser(true);
  else if (_created) [self finishClose];  // already gone
  // else: still being created; didCreate closes it as soon as it exists.
}

- (void)finishClose {
  void (^done)(void) = _closeCompletion;
  _closeCompletion = nil;
  _selfRef = nil;
  if (done) done();
}

- (void)close { [self closeWithCompletion:nil]; }
@end

// MARK: - PCApplication

@implementation PCApplication {
  BOOL _handlingSendEvent;
}
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)v { _handlingSendEvent = v; }
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent scoped;
  [super sendEvent:event];
}
@end

// MARK: - PCRuntime

@implementation PCRuntime

+ (BOOL)initializeWithCachePath:(NSString *)cachePath {
  g_loader = new CefScopedLibraryLoader();
  if (!g_loader->LoadInMain()) return NO;

  CefMainArgs args(0, nullptr);
  NSBundle *main = NSBundle.mainBundle;
  CefSettings s;
  s.no_sandbox = true;
  s.external_message_pump = true;
  s.log_severity = LOGSEVERITY_WARNING;
  CefString(&s.root_cache_path) = cachePath.UTF8String;
  CefString(&s.cache_path) = [cachePath stringByAppendingPathComponent:@"Default"].UTF8String;
  CefString(&s.main_bundle_path) = main.bundlePath.UTF8String;
  CefString(&s.framework_dir_path) =
      [main.privateFrameworksPath stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"].UTF8String;
  CefRefPtr<PCApp> app = new PCApp();
  if (!CefInitialize(args, s, app, nullptr)) return NO;
  SchedulePump(0);
  // Safety net in case a scheduled pump is ever missed.
  NSTimer *safety = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *) { PumpOnce(); }];
  safety.tolerance = 0.05;
  [NSRunLoop.mainRunLoop addTimer:safety forMode:NSRunLoopCommonModes];
  return YES;
}

+ (void)setAdBlocking:(BOOL)on { g_adBlock.store(on); }

+ (void)shutdown {
  for (PCBrowser *b : std::set<PCBrowser *>(g_browsers)) [b close];
  // Pages that haven't confirmed closing within a moment are closed by CefShutdown itself (it takes well under a second);
  // waiting longer only made quitting hang for five seconds.
  for (int i = 0; i < 40 && !g_browsers.empty(); i++) {
    CefDoMessageLoopWork();
    [NSThread sleepForTimeInterval:0.01];
  }
  g_shutDown = YES;
  CefShutdown();
  delete g_loader;
  g_loader = nullptr;
}

+ (int)runHelperWithArgc:(int)argc argv:(char **)argv {
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  CefMainArgs args(argc, argv);
  return CefExecuteProcess(args, nullptr, nullptr);
}
@end
