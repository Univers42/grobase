/**
 * Gradient Background Component
 * Animated, accessibility-friendly gradient mesh
 */
import './GradientBackground.css';

export function GradientBackground() {
  return (
    <div className="devboard-gradient-bg" aria-hidden="true">
      <div className="gradient-orb gradient-orb--primary" />
      <div className="gradient-orb gradient-orb--secondary" />
      <div className="gradient-orb gradient-orb--tertiary" />
      <div className="gradient-orb gradient-orb--accent" />
      <div className="gradient-noise" />
    </div>
  );
}
