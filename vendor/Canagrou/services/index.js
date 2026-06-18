// services/index.js — the public surface of the services/ layer: capabilities
// Grobase does NOT cover (photo composition, comment notification, relative
// time). Pure modules — none import the baas client; they take inputs and return
// Blobs/strings (notifier receives `baas` as a parameter).

export { composition } from './composition/index.js';
export { notifier } from './notifier/index.js';
export { timeAgo } from './time/index.js';
