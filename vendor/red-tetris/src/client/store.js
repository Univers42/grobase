import { combineReducers, createStore, applyMiddleware } from 'redux';
import { thunk } from 'redux-thunk';
import {
  connectionReducer,
  gameReducer,
  boardReducer,
  uiReducer,
} from './reducers';

const rootReducer = combineReducers({
  connection: connectionReducer,
  game: gameReducer,
  board: boardReducer,
  ui: uiReducer,
});

const store = createStore(rootReducer, applyMiddleware(thunk));

export default store;
