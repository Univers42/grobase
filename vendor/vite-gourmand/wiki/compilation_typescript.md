To compile the frontend and see Typescript and build errors, we have two main options:
1. Run `npm run build` in the frontend directory. This will create a production build and show any errors that occur during the compilation process.
2. Run `npm run dev` in the frontend directory. This will start the development server
3. In the frontend directory, we can also run `npx tsc --noEmit` to check for TypeScript errors without generating any output files. This is a quick way to see if there are any type errors in the code.