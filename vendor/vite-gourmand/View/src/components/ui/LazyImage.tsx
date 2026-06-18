/**
 * LazyImage — Image with skeleton placeholder
 *
 * Shows a shimmer/skeleton placeholder while the image loads,
 * then fades in the actual image. Falls back to a neutral placeholder
 * if the image fails to load.
 */
import { useState, useCallback } from 'react';

interface LazyImageProps {
  src: string;
  alt: string;
  className?: string;
  fallback?: string;
  srcSet?: string;
  sizes?: string;
  width?: number;
  height?: number;
  loading?: 'eager' | 'lazy';
  fetchPriority?: 'high' | 'low' | 'auto';
}

const DEFAULT_FALLBACK = '/menu-fallback-640.webp';

export default function LazyImage({
  src,
  alt,
  className = '',
  fallback = DEFAULT_FALLBACK,
  srcSet,
  sizes,
  width,
  height,
  loading = 'lazy',
  fetchPriority = 'auto',
}: Readonly<LazyImageProps>) {
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState(false);

  const handleLoad = useCallback(() => setLoaded(true), []);
  const handleError = useCallback(() => {
    setError(true);
    setLoaded(true); // Stop showing skeleton on error too
  }, []);

  return (
    <div className={`relative overflow-hidden ${className}`}>
      {/* Skeleton placeholder — visible while loading */}
      {!loaded && (
        <div className="absolute inset-0 bg-[#1A1A1A]/5">
          <div className="absolute inset-0 lazy-image-shimmer" />
        </div>
      )}

      {/* Actual image */}
      <img
        src={error ? fallback : src}
        srcSet={error ? undefined : srcSet}
        sizes={sizes}
        alt={alt}
        width={width}
        height={height}
        loading={loading}
        fetchPriority={fetchPriority}
        decoding="async"
        onLoad={handleLoad}
        onError={handleError}
        className={`w-full h-full object-cover transition-opacity duration-300 ${
          loaded ? 'opacity-100' : 'opacity-0'
        }`}
      />
    </div>
  );
}
