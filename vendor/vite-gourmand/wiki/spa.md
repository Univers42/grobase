# Single page Application

As we are looking for render speedness for the webpage we're building. we'll use React library of javascript written in typescript with which we will handle navigation with routes. 
Henceforth, when navigating to a new page, (e.g., menu, /contact), the SPA updates the URL and dynamically render the corresponding REACT component -- without reloading the page or fetching a new HTML file.

- The content is managed by our `.tsx` or `.ts` files, not by separate HTML files

SPAs are generally faster for users afthe the initial load. Once the app is loaded navigation between pages is instant because only the necessary data and components are updated. There's no ful page reload. This results in a smoother and more responsive user experience.

> That's why we have only one index.html