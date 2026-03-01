declare module "*.wgsl?url" {
    const content: string;
    export default content;
}

declare module "*.wgsl?raw" {
    const content: string;
    export default content;
}

declare module "*.wasm?url" {
    const url: string;
    export default url;
}
