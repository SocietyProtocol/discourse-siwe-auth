import Controller from "@ember/controller";
import { withPluginApi } from "discourse/lib/plugin-api";
import loadScript from "discourse/lib/load-script";
import { SIWE_BUNDLE_URL } from "../lib/siwe-bundle-version";

export default class SiweAuthIndexController extends Controller {
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

    if (window.mountSiwe) {
      window.mountSiwe("#siwe-mount", {
        csrfToken,
        callbackUrl: "/auth/siwe/callback",
        messageUrl: "/discourse-siwe/message",
        walletConnectProjectId: settings.projectId,
        statement: settings.statement,
      });
    }
  }
}
