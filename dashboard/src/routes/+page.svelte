<script lang="ts">
    import { onMount } from 'svelte';
    let messages: string[] = [];

    onMount(() => {
        const source = new EventSource('/');

        source.onmessage = (event) => {
            try {
                const data = JSON.parse(event.data);
                if (data.message) {
                    messages = [...messages, data.message];
                }
            } catch (error) {
                console.error('Error parsing SSE data:', error);
            }
        };

        source.onerror = () => {
            console.error('SSE error, attempting to reconnect...');
        };

        return () => {
            source.close();
        };
    });
</script>

<ul>
    {#each messages as msg}
        <li>{msg}</li>
    {/each}
</ul>

<style>
    ul {
        list-style-type: none;
        padding: 0;
    }
    li {
        margin: 5px 0;
        padding: 10px;
        background-color: #f0f0f0;
        border-radius: 5px;
    }
</style>