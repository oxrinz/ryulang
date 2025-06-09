<script lang="ts">
    import { Background, BackgroundVariant, MiniMap, SvelteFlow } from "@xyflow/svelte";
    import "@xyflow/svelte/dist/style.css";
    import Node from "$components/node.svelte";
    import type { Data } from "$lib";
    import { onMount } from "svelte";
    import ELK from "elkjs/lib/elk.bundled.js";

    let nodes = $state.raw<any>([]);
    let edges = $state.raw<any>([]);

    const elk = new ELK();

    async function layoutNodes(nodes: any[], edges: any[]) {
        const elkGraph = {
            id: "root",
            children: nodes.map((node) => ({
                id: node.id,
                width: 150,
                height: 50,
            })),
            edges: edges.map((edge) => ({
                id: edge.id,
                sources: [edge.source],
                targets: [edge.target],
            })),
        };

        try {
            const layout = await elk.layout(elkGraph, {
                layoutOptions: {
                    "elk.algorithm": "mrtree",
                    "elk.direction": "LEFT",
                    "elk.spacing.nodeNode": "50",
                },
            });

            return nodes.map((node) => {
                const elkNode = layout.children?.find((n) => n.id === node.id);
                return {
                    ...node,
                    position: {
                        x: elkNode?.x || 0,
                        y: elkNode?.y || 0,
                    },
                };
            });
        } catch (error) {
            console.error("ELK layout error:", error);
            return nodes;
        }
    }

    onMount(() => {
        const source = new EventSource("/");

        source.onmessage = async (event) => {
            try {
                console.log(event.data);
                const data: Data = JSON.parse(event.data);
                const newNodes = data.nodes.map((node) => ({
                    id: node.id,
                    type: "custom",
                    position: { x: 0, y: 0 },
                    data: { label: node.title },
                }));
                const newEdges = data.edges.map((edge) => ({
                    id: `e${edge.source}-${edge.target}`,
                    source: edge.source.toString(),
                    target: edge.target.toString(),
                }));

                nodes = await layoutNodes(newNodes, newEdges);
                edges = newEdges;

                console.log(data);
            } catch (error) {
                console.error("Error parsing SSE data:", error);
            }
        };

        source.onerror = () => {
            console.error("SSE error, attempting to reconnect...");
        };

        return () => {
            source.close();
        };
    });

    const nodeTypes = {
        custom: Node,
    };
</script>

<div style:width="100vw" style:height="100vh">
    <SvelteFlow
        proOptions={{ hideAttribution: true }}
        bind:nodes
        bind:edges
        {nodeTypes}
    >
    <Background variant={BackgroundVariant.Dots} patternColor="#444" />
        <MiniMap
        bgColor="#333"
        maskColor="#111"
            nodeColor="#fff"
            zoomable
            pannable
        />
    </SvelteFlow>
</div>

<style>
</style>
