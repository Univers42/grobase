// editor-state.js — the per-mount mutable state bag for the editor page. Kept in
// its own module (not a module-level global) so each editor mount gets a fresh,
// isolated object holding the webcam stream, chosen overlay, and capture flags.

/**
 * createEditorState returns a fresh editor state object: input mode, webcam
 * stream + overlay-loop teardown, the selected overlay URL, an uploaded file,
 * and the busy guard. One per editor mount.
 */
export function createEditorState() {
  return {
    mode: 'webcam',
    stream: null,
    stopOverlay: null,
    overlayTimer: 0,
    overlayUrl: null,
    uploadFile: null,
    busy: false,
  };
}
