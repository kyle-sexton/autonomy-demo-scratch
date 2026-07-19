import { defineConfig, mergeConfig } from "vitest/config";

import base from "../../../vitest.config.base.ts";

export default mergeConfig(
  base,
  defineConfig({
    test: {},
  }),
);
