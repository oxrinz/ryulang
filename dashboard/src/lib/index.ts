export interface Node {
    id: string,
    title: string,
}

export interface Edge {
    source: number,
    target: number
}

export interface Data {
    nodes: Node[],
    edges: Edge[]
}