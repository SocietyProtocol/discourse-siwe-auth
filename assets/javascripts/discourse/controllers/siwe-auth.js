import Controller from "@ember/controller";
import { withPluginApi } from "discourse/lib/plugin-api";
import loadScript from "discourse/lib/load-script";
import { SIWE_BUNDLE_URL } from "../lib/siwe-bundle-version";

export default class SiweAuthController extends Controller {
  constructor() {
    super(...arguments);
    this.initAuth();
  }

  async initAuth() {
    const settings = withPluginApi("0.11.7", (api) => {
      const siteSettings =
        api.container.lookup("service:site-settings") ||
        api.container.lookup("site-settings:main");
      return {
        projectId: siteSettings.siwe_project_id,
        statement: siteSettings.siwe_statement,
      };
    });

    const csrfToken =
      document
        .querySelector('meta[name="csrf-token"]')
        ?.getAttribute("content") || "";

    // siwe.iife.js?v=<content hash>: Discourse serves the bundle as immutable,
    // so only a new URL makes browsers and the CDN fetch a rebuilt bundle.
    await loadScript(SIWE_BUNDLE_URL);

    // Mount once: a second mountSiwe on the same element throws (it already
    // hosts the wallet UI's shadow root).
    const host = document.querySelector("#siwe-mount");
    if (window.mountSiwe && host && !host.shadowRoot) {
      window.mountSiwe(host, {
        csrfToken,
        callbackUrl: "/auth/siwe/callback",
        messageUrl: "/discourse-siwe/message",
        walletConnectProjectId: settings.projectId,
        statement: settings.statement,
      });
    }
  }
}
