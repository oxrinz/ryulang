<script lang="ts">
    import { SvelteFlow } from "@xyflow/svelte";
    import "@xyflow/svelte/dist/style.css";
    import Node from "$components/node.svelte";
    import type { Data } from "$lib";
    import { onMount } from "svelte";

    let nodes = $state.raw<any>([]);

    let edges = $state.raw<any>([]);

    onMount(() => {
        const source = new EventSource("/");

        source.onmessage = (event) => {
            try {
                console.log(event.data);
                const data: Data = JSON.parse(event.data);
                const newNodes = data.nodes.map((node, index) => ({
                    id: node.id,
                    type: "custom",
                    position: { x: 0, y: index * 100 },
                    data: { label: node.title },
                }));
                const newEdges = data.edges.map((edge, index) => ({
                    id: `e${edge.source}-${edge.target}`,
                    source: edge.source.toString(),
                    target: edge.target.toString(),
                }));

                nodes = newNodes;
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
    />
</div>

<style>
    :global(.svelte-flow) {
        background: #0080ff;
        border: 1px solid #000000;
    }
</style>
