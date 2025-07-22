export interface Node {
    id: number,
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

export interface DataConfiguration {
    id: string,
    title: string,
    data: Data
}