export type RootStackParamList = {
  '(auth)': undefined;
  '(tabs)': undefined;
  'event/[id]': { id: string };
  'event/create': undefined;
  'playlist/[id]': { id: string };
  'playlist/create': undefined;
  friends: undefined;
  preferences: undefined;
  subscription: undefined;
  devices: undefined;
  delegations: undefined;
  settings: undefined;
  'user-search': undefined;
};

export type AuthStackParamList = {
  login: undefined;
  register: undefined;
  'forgot-password': undefined;
};

export type TabParamList = {
  home: undefined;
  search: undefined;
  events: undefined;
  playlists: undefined;
  profile: undefined;
};

declare global {
  namespace ReactNavigation {
    interface RootParamList extends RootStackParamList {}
  }
}
