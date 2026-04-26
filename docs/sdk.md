A **SDK** is one of the most important concept in software development. It stands for "Software Development Kit" and is a collection of tools, libraries, documentation, and code samples that developers can use to build applications for a specific platform or service. An SDK provides a set of pre-built functionalities and APIs (Application Programming Interfaces) that allow developers to interact with a service or platform without having to build everything from scratch.

a SDK typically includes:

- **Libraries**: Pre-written code that developers can use to perform common tasks, such as making API calls, handling authentication, or managing data.
- **Documentation**: Detailed information on how to use the SDK, including API references, guides
  , and examples.
- **Tools**: Command-line tools or graphical interfaces that assist in development, testing, and debugging.
- **Code Samples**: Example code snippets or projects that demonstrate how to use the SDK

SDKs are designed to simplify the development process and enable developers to quickly integrate with a service or platform. They abstract away the complexities of interacting with APIs and provide a more user-friendly interface for developers to work with. SDKs are commonly used in various domains, including mobile app development, web development, cloud services, and more.

in this context, the mini-BaaS SDK would be a collection of tools and libraries that developers can use to interact with the mini-BaaS platform, allowing them to easily integrate its functionalities into their applications.

The canonical SDK now lives as the `packages/mini-baas-sdk` submodule in the infra repository. It is still published/consumed as `@mini-baas/js`.

example for baas:
without sdk

```js
fetch("https://api.example.com/documents", {
  method: "POST",
  headers: {
    authorization: "Bearer user-jwt",
    "x-api-key": "public-anon-key",
    "content-type": "application/json",
  },
  body: JSON.stringify({ query: "users" }),
})
  .then((res) => res.json())
  .then((data) => console.log(data))
  .catch((err) => console.error(err));
```

with sdk:

```js
import { createClient } from "@mini-baas/js";
const client = new BaaSClient("Token");
const users = await client.users.list();
```

The baas get a real product when the product has:

- API (backend)
- SDK (frontend)
- infrastructure (devops)
