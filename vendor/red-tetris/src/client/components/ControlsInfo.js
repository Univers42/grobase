/**
 * ControlsInfo: shows key bindings.
 * Pure functional component - no `this`.
 */
const ControlsInfo = () => (
  <div className="controls-info">
    <div><span>←→</span> Move</div>
    <div><span>↑</span> Rotate</div>
    <div><span>↓</span> Soft drop</div>
    <div><span>Space</span> Hard drop</div>
  </div>
);

export default ControlsInfo;
