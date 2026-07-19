import { type CliExtensionStrategies, defaultCliExtensionStrategies } from "./cli-extensions.js";
import { type ContainerRuntime, createDockerContainerRuntime } from "./container-runtime.js";

/**
 * GoF Abstract Factory — bundles strategies + container runtime for one run.
 * Tests swap individual strategies without module mocks.
 */
export interface RunLoopDependencies {
  readonly strategies: CliExtensionStrategies;
  readonly containerRuntime: ContainerRuntime;
}

export function createDefaultRunLoopDependencies(): RunLoopDependencies {
  return {
    strategies: defaultCliExtensionStrategies,
    containerRuntime: createDockerContainerRuntime(),
  };
}
