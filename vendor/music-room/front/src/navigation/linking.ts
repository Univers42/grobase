export const linking = {
  prefixes: ['musicroom://', 'https://musicroom.app'],
  config: {
    screens: {
      '(auth)': {
        screens: {
          login: 'login',
          register: 'register',
          'forgot-password': 'forgot-password',
        },
      },
      '(tabs)': {
        screens: {
          home: '',
          search: 'search',
          events: 'events',
          playlists: 'playlists',
          profile: 'profile',
        },
      },
      'event/[id]': 'event/:id',
      'event/create': 'event/create',
      'playlist/[id]': 'playlist/:id',
      'playlist/create': 'playlist/create',
      friends: 'friends',
      preferences: 'preferences',
      subscription: 'subscription',
      devices: 'devices',
      delegations: 'delegations',
      settings: 'settings',
      'user-search': 'user-search',
    },
  },
};

export const navigationRef = {
  isReady: false,
};
