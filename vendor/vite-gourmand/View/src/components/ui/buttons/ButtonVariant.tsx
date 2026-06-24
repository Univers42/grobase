import * as React from 'react';
import { Slot } from '@radix-ui/react-slot';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../utils';

/**
 * Button variants following the graphical chart:
 * - Deep Bordeaux (#722F37) - Primary actions
 * - Champagne (#D4AF37) - Secondary/accent
 * - Crème (#FFF8F0) - Light backgrounds
 * - Vert olive (#556B2F) - Success states
 * - Noir charbon (#1A1A1A) - Text/dark elements
 */
const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap font-medium transition-all duration-300 disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg:not([class*='size-'])]:size-4 shrink-0 [&_svg]:shrink-0 outline-none focus-visible:ring-2 focus-visible:ring-offset-2",
  {
    variants: {
      variant: {
        // Primary - Deep Bordeaux
        default:
          'bg-[#722F37] text-white hover:bg-[#5a252c] focus-visible:ring-[#722F37] shadow-lg shadow-[#722F37]/20 hover:shadow-[#722F37]/30',
        // Champagne accent
        champagne:
          'bg-[#D4AF37] text-[#1A1A1A] hover:bg-[#c9a431] focus-visible:ring-[#D4AF37] shadow-lg shadow-[#D4AF37]/20',
        // Destructive
        destructive:
          'bg-red-600 text-white hover:bg-red-700 focus-visible:ring-red-500 shadow-lg shadow-red-500/20',
        // Outline - Bordeaux border
        outline:
          'border-2 border-[#722F37] bg-transparent text-[#722F37] hover:bg-[#722F37] hover:text-white focus-visible:ring-[#722F37]',
        // Outline light - for dark backgrounds — gradient fill on hover
        outlineLight:
          'border-2 border-white/80 text-white focus-visible:ring-white relative overflow-hidden bg-transparent z-[1] before:absolute before:inset-0 before:z-[-1] before:bg-gradient-to-r before:from-[#D4AF37] before:to-[#f0d78c] before:origin-left before:scale-x-0 before:transition-transform before:duration-500 before:ease-out hover:before:scale-x-100 hover:text-[#1A1A1A] hover:border-[#D4AF37]',
        // Secondary - Light cream
        secondary:
          'bg-[#FFF8F0] text-[#722F37] hover:bg-[#f5ede3] focus-visible:ring-[#722F37] border border-[#722F37]/10',
        // Ghost
        ghost:
          'text-[#1A1A1A] hover:bg-[#FFF8F0] hover:text-[#722F37] focus-visible:ring-[#722F37]',
        // Link
        link: 'text-[#722F37] underline-offset-4 hover:underline focus-visible:ring-[#722F37]',
        // Olive/Success
        success:
          'bg-[#556B2F] text-white hover:bg-[#475a27] focus-visible:ring-[#556B2F] shadow-lg shadow-[#556B2F]/20',
      },
      size: {
        default: 'h-11 px-6 py-2 text-sm rounded-lg',
        sm: 'h-9 px-4 py-2 text-sm rounded-lg',
        lg: 'h-12 px-8 py-3 text-base rounded-xl',
        xl: 'h-14 px-10 py-4 text-lg rounded-xl',
        icon: 'size-10 rounded-lg',
      },
    },
    defaultVariants: {
      variant: 'default',
      size: 'default',
    },
  },
);

function Button({
  className,
  variant,
  size,
  asChild = false,
  ...props
}: React.ComponentProps<'button'> &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean;
  }) {
  const Comp = asChild ? Slot : 'button';

  return (
    <Comp
      data-slot="button"
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  );
}

// eslint-disable-next-line react-refresh/only-export-components
export { Button, buttonVariants };
