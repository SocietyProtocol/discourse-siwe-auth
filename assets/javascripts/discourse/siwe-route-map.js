// One flat route, with its controller and template at controllers/siwe-auth.js
// and templates/siwe-auth.gjs. Do not nest an index route under it with a
// controllers/siwe-auth/index.js: the module loader resolves
// controllers/siwe-auth to controllers/siwe-auth/index, so Ember would build
// that controller for both siwe-auth and siwe-auth.index and mount the wallet
// UI twice (ui/e2e/plugin-layout.spec.ts checks for this).
export default function () {
  this.route("siwe-auth", { path: "/discourse-siwe/auth" });
}
