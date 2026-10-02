/// Inkbound has no backend of its own: the library, history and settings
/// all live in local storage, and a backup is a JSON file in a folder you
/// chose. What is left here is the OAuth configuration for the tracker
/// integrations and the website's share page - the only other things
/// that talk to anyone.
class Environment {
  /// Host of the share "open" page, which is what turns a shared link back
  /// into an in-app title (it redirects to [openLinkScheme] `://open?…`).
  ///
  /// Still upstream's host, on purpose and for one reason only: it is the
  /// deployed page that does that redirect. There is no Inkbound equivalent,
  /// so pointing elsewhere breaks share-to-app. It is not this app's site,
  /// it is never shown in the UI, and nothing else here talks to it. Host
  /// your own copy of that page and repoint this to retire the dependency.
  static const String siteBaseUrl = 'https://zangetsu.online';

  /// Share links point here. The page opens the app if installed (via the
  /// [openLinkScheme] scheme below), otherwise offers the download.
static const String siteOpenUrl = '$siteBaseUrl/open/';

  /// The "open" page redirects to `zangetsu://open?…`; an installed app catches
  /// it (see [OpenLinkService] + the Android manifest intent-filter).
  static const String openLinkScheme = trackerRedirectScheme; // 'zangetsu'
  static const String openLinkHost = 'open';

  // ── Tracker OAuth ──────────────────────────────────────────────────────────
  // All redirects share the zangetsu:// scheme; each has its own host with a
  // matching Android intent-filter. Client secrets are embedded where the
  // provider's token exchange requires it (MAL = PKCE, no secret; Simkl needs
  // one) — standard for these APIs and low-risk.
  static const String trackerRedirectScheme = 'zangetsu';

  // AniList — implicit grant (token in URL fragment, 1-year, no secret).
  static const String anilistClientId = '43052';
  static const String anilistRedirectHost = 'anilist-auth';
  static String get anilistRedirectUri => '$trackerRedirectScheme://$anilistRedirectHost';

  // MyAnimeList — OAuth2 PKCE (plain), no client secret.
  static const String malClientId = 'ac006943589381143c4c4e54eac93a89';
  static const String malRedirectHost = 'mal-auth';
  static String get malRedirectUri => '$trackerRedirectScheme://$malRedirectHost';

  // Simkl wants these on EVERY request (url params + a real User-Agent), or
  // the call is invisible in their debug log and they can't help when
  // something breaks. See https://api.simkl.org/conventions/headers.
  static const String simklAppName = 'zangetsu';
  static const String simklApiHost = 'api.simkl.com';
  static const String simklDataHost = 'data.simkl.in';

  // Simkl — OAuth2 authorization-code (needs the secret to exchange the code).
  static const String simklClientId = '8b847b09206ccdb0b3de4cc1293d6dd7d355821f5c179c57315da8ba9030eb53';
  static const String simklClientSecret = '34ba8e5ac7c8a5c27926dfdf78205e5b913de9928361cb5a243558239298c96d';
  static const String simklRedirectHost = 'simkl-auth';
  static String get simklRedirectUri => '$trackerRedirectScheme://$simklRedirectHost';

  // Back-compat alias (older AniList code referenced this name).
  // ── MangaBaka ────────────────────────────────────────────────────────────
  //
  // Manga/manhwa/manhua only — no anime list, which is why `supportsReading`
  // is the one thing it answers true to.
  //
  // A PUBLIC OAuth client: no secret, PKCE (S256) instead, which is the right
  // shape for an installed app — anything shipped in the APK can be extracted.
  // Endpoints come from https://mangabaka.org/.well-known/openid-configuration
  // (the `.org` host; `api.mangabaka.org/.well-known/*` is 404). MangaBaka's
  // own API docs mention neither OAuth nor tokens, so prefer the discovery
  // document over the docs if they ever disagree.
  static const String mangabakaClientId = 'EkBIEASsBsfRvPKGevUZIcRLSdubVHPK';
  static const String mangabakaRedirectHost = 'mangabaka-auth';
  static String get mangabakaRedirectUri =>
      '$trackerRedirectScheme://$mangabakaRedirectHost';
  static const String mangabakaAuthorizeUrl =
      'https://mangabaka.org/auth/oauth2/authorize';
  static const String mangabakaTokenUrl =
      'https://mangabaka.org/auth/oauth2/token';
  static const String mangabakaRevokeUrl =
      'https://mangabaka.org/auth/oauth2/revoke';
  static const String mangabakaApi = 'https://api.mangabaka.org';

  /// `library.write` is an official scope — third-party writes are supported,
  /// not a workaround. `offline_access` is what returns a refresh token.
  /// `openid` is required by `/v1/my/profile`: with the other four granted it
  /// still answered `BAD_REQUEST: Missing required scope`, which is the OIDC
  /// identity scope missing rather than any library permission.
  static const String mangabakaScopes =
      'openid profile library.read library.write offline_access';

  static const String anilistRedirectScheme = trackerRedirectScheme;
}
