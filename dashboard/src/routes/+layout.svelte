<script lang="ts">
    import '../app.css';
    import type { DataConfiguration } from "$lib";
    import { onMount } from "svelte";
    import { page } from "$app/stores";
    import { goto } from "$app/navigation";

    let { children } = $props();
    let configurations = $state<DataConfiguration[]>([]);

    const selectedConfigId = $derived($page.params.id || null);

    onMount(() => {
        console.log("Setting up EventSource connection to /");
        const source = new EventSource("/");

        source.onopen = () => {
            console.log("SSE connection opened");
        };

        source.onmessage = async (event) => {
            try {
                console.log("Received SSE message:", event.data);
                const data: DataConfiguration[] = JSON.parse(event.data);
                configurations = data;
                console.log("Updated configurations:", data);
                
                // Auto-navigate to first config if on home page and no selection
                if (data.length > 0 && $page.route.id === '/' && !selectedConfigId) {
                    goto(`/step/${data[0].id}`);
                }
            } catch (error) {
                console.error("Error parsing SSE data:", error);
                console.error("Raw data was:", event.data);
            }
        };

        source.onerror = (error) => {
            console.error("SSE error:", error);
            console.error("ReadyState:", source.readyState);
        };

        return () => {
            console.log("Closing SSE connection");
            source.close();
        };
    });

    function selectConfiguration(configId: string) {
        goto(`/step/${configId}`);
    }
</script>

<div class="flex h-screen bg-neutral-900">
    <!-- Sidebar -->
    <div class="w-80 bg-neutral-800 border-r border-neutral-700 flex flex-col">
        <div class="p-6 border-b border-neutral-700">
            <a href="/" class="block">
                <h1 class="text-2xl font-bold text-white">ryu!</h1>
                <p class="text-sm text-neutral-400 mt-1">Select a graph to visualize</p>
            </a>
        </div>
        
        <div class="flex-1 overflow-y-auto">
            {#if configurations.length === 0}
                <div class="p-6">
                    <p class="text-neutral-400 text-sm">No graph configurations available. Send data to see graphs here.</p>
                </div>
            {:else}
                <div class="p-4">
                    {#each configurations as config}
                        <button
                            onclick={() => selectConfiguration(config.id)}
                            class="w-full text-left p-4 mb-3 rounded-lg border transition-colors {selectedConfigId === config.id ? 'bg-blue-900 border-blue-600 ring-1 ring-blue-500' : 'bg-neutral-700 border-neutral-600 hover:bg-neutral-600'}"
                        >
                            <h3 class="font-semibold text-white mb-1">{config.title}</h3>
                            <p class="text-sm text-neutral-300">
                                {config.data.nodes.length} nodes, {config.data.edges.length} edges
                            </p>
                        </button>
                    {/each}
                </div>
            {/if}
        </div>
    </div>

    <!-- Main Content -->
    <div class="flex-1 bg-neutral-900">
        {@render children()}
    </div>
</div>
