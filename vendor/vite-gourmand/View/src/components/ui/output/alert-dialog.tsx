'use client';

import * as React from 'react';
import * as AlertDialogPrimitive from '@radix-ui/react-alert-dialog';

export function AlertDialog({ ...props }: Readonly<React.ComponentProps<typeof AlertDialogPrimitive.Root>>) {
  return <AlertDialogPrimitive.Root data-slot="alert-dialog" {...props} />;
}
