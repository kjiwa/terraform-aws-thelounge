// Shell configuration for the status page. The page shares an origin with The
// Lounge client, which keeps its session token in localStorage["token"] and
// its theme in localStorage["settings"].
(function () {
  // The Lounge's "morning" theme is dark; every other value falls back to its
  // default (light) theme. Colors are upstream style.css/morning.css, adjusted
  // where the original misses 4.5:1 text contrast on the card.
  var LIGHT = { secondary: '#3d7e41', 'on-surface': '#222222' };
  var DARK = {
    surface: '#303e4a',
    card: '#28333d',
    'on-surface': '#f3f3f3',
    muted: '#b7c5d1',
    secondary: '#77abd9',
    'on-secondary': '#1b1b1b',
    bad: '#ff8a80',
  };

  function loungeTheme() {
    try {
      return JSON.parse(localStorage.getItem('settings') || '{}').theme;
    } catch (e) {
      return undefined;
    }
  }

  window.STATUS_CONFIG = {
    pathPrefix: '/status',
    title: 'The Lounge status',
    authHeader: 'X-Lounge-Token',
    tokenKey: 'token',
    signInUrl: '/',
    disabledPanels: ${jsonencode(disabled)},
    theme: function () {
      var dark = loungeTheme() === 'morning';
      return { scheme: dark ? 'dark' : 'light', primary: null, tokens: dark ? DARK : LIGHT };
    },
  };
})();
