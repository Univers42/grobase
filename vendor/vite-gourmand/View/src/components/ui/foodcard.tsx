import React, { useEffect, useState } from 'react';
import styles from './foodcard.module.css';
import { FALLBACK_IMAGE_URL } from '../../styles/constant';

export interface FoodCardProps {
  name: string;
  description?: string;
  price?: number;
  imageUrl?: string;
}

export const FoodCard: React.FC<FoodCardProps> = ({ name, description, price, imageUrl }) => {
  const [randomImage, setRandomImage] = useState<string | null>(null);

  useEffect(() => {
    if (!imageUrl) setRandomImage(FALLBACK_IMAGE_URL);
  }, [imageUrl]);
  return (
    <div className={styles.card}>
      <div className={styles.imageWrapper}>
        <img
          src={imageUrl || randomImage || FALLBACK_IMAGE_URL}
          alt={name}
          className={styles.image}
          loading="lazy"
          decoding="async"
        />
      </div>
      <div className={styles.info}>
        <h3 className={styles.name}>{name}</h3>
        {description && <p className={styles.description}>{description}</p>}
        {price !== undefined && <div className={styles.price}>{price.toFixed(2)} €</div>}
      </div>
    </div>
  );
};
