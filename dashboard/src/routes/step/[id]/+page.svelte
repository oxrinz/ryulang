<script lang="ts">
    import { SvelteFlow, Background, MiniMap, BackgroundVariant } from "@xyflow/svelte";
    import "@xyflow/svelte/dist/style.css";
    import Node from "$components/node.svelte";
    import type { DataConfiguration } from "$lib";
    import { onMount } from "svelte";
    import { page } from '$app/stores';
    import ELK from "elkjs/lib/elk.bundled.js";

    let nodes = $state.raw<any>([]);
    let edges = $state.raw<any>([]);
    let configuration = $state<DataConfiguration | null>(null);
    let loading = $state(true);
    let error = $state<string | null>(null);

    const id = $derived($page.params.id);

    const elk = new ELK();

    async function layoutNodes(nodes: any[], edges: any[]) {
        const elkGraph = {
            id: "root",
            children: nodes.map((node) => ({
                id: node.id,
                width: 350,
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
                    "elk.algorithm": "layered",
                    "elk.direction": "LEFT",
                    "elk.spacing.nodeNode": "140",
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

    async function loadConfiguration(configId: string) {
        try {
            loading = true;
            error = null;
            const response = await fetch(`/?id=${configId}`);
            
            if (!response.ok) {
                if (response.status === 404) {
                    error = "Configuration not found";
                } else {
                    error = "Failed to load configuration";
                }
                return;
            }

            const config: DataConfiguration = await response.json();
            configuration = config;

            const newNodes = config.data.nodes.map((node) => ({
                id: node.id.toString(),
                type: "custom",
                position: { x: 0, y: 0 },
                data: { label: node.title },
            }));
            const newEdges = config.data.edges.map((edge) => ({
                id: `e${edge.source}-${edge.target}`,
                source: edge.source.toString(),
                target: edge.target.toString(),
            }));

            nodes = await layoutNodes(newNodes, newEdges);
            edges = newEdges;
        } catch (err) {
            console.error("Error loading configuration:", err);
            error = "Failed to load configuration";
        } finally {
            loading = false;
        }
    }

    $effect(() => {
        if (id) {
            loadConfiguration(id);
        }
    });

    const nodeTypes = {
        custom: Node,
    };
</script>

<div class="flex flex-col h-full">
    {#if loading}
        <div class="flex items-center justify-center h-full">
            <p class="text-lg text-neutral-400">Loading graph...</p>
        </div>
    {:else if error}
        <div class="flex flex-col items-center justify-center h-full">
            <p class="text-red-600 text-lg mb-4">{error}</p>
            <a href="/" class="text-blue-600 hover:underline">← Back to Dashboard</a>
        </div>
    {:else if configuration}
        <div class="bg-neutral-800 border-b border-neutral-700 p-4">
            <h2 class="text-xl font-bold text-white">{configuration.title}</h2>
            <p class="text-sm text-neutral-400">
                {configuration.data.nodes.length} rirops
            </p>
        </div>
        <div class="flex-1 relative">
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
    {/if}
</div>