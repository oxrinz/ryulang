import type { RequestHandler } from '@sveltejs/kit';
import type { Data, Node, Edge, DataConfiguration } from '$lib';

var currentConfigurations: DataConfiguration[] = [];

type StreamInfo = {
    controller: ReadableStreamDefaultController;
    close: () => void;
};

const activeStreams: Set<StreamInfo> = new Set();

export const POST: RequestHandler = async ({ request }) => {
    try {
        const rawBody = await request.text();
        console.log(rawBody)
        let configurations;
        try {
            configurations = JSON.parse(rawBody);
            if (!isValidConfigurations(configurations)) {
                console.error('POST: JSON is not valid configuration')
                console.error('POST: Validation failed for:', JSON.stringify(configurations, null, 2))
                return new Response(JSON.stringify({ error: 'Invalid DataConfiguration array format' }), {
                    status: 400,
                    headers: { 'Content-Type': 'application/json' }
                });
            }
        } catch (parseError: any) {
            console.error('POST: JSON parse error:', parseError);
            return new Response(JSON.stringify({ error: 'Invalid JSON', details: parseError.message }), {
                status: 400,
                headers: { 'Content-Type': 'application/json' }
            });
        }

        currentConfigurations = configurations;
        console.log('POST: Updated configurations, sending to', activeStreams.size, 'active streams');

        const streamsToRemove = new Set<StreamInfo>();
        for (const stream of activeStreams) {
            try {
                const dataStr = JSON.stringify(currentConfigurations).replace(/\n/g, '');
                const message = `data: ${dataStr}\n\n`;
                console.log('POST: Sending SSE message:', message.substring(0, 100) + '...');
                stream.controller.enqueue(new TextEncoder().encode(message));
            } catch (error) {
                console.error('POST: Error sending SSE update to stream:', error);
                stream.close();
                streamsToRemove.add(stream);
            }
        }
        // Remove failed streams
        for (const stream of streamsToRemove) {
            activeStreams.delete(stream);
        }

        return new Response(JSON.stringify({ status: 'Data received' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
        });
    } catch (error: any) {
        console.error('POST: Unexpected error:', error);
        return new Response(JSON.stringify({ error: 'Server error', details: error.message }), {
            status: 500,
            headers: { 'Content-Type': 'application/json' }
        });
    }
};

export const GET: RequestHandler = async ({ url }) => {
    const configId = url.searchParams.get('id');
    
    if (configId) {
        const config = currentConfigurations.find(c => c.id === configId);
        if (!config) {
            return new Response(JSON.stringify({ error: 'Configuration not found' }), {
                status: 404,
                headers: { 'Content-Type': 'application/json' }
            });
        }
        return new Response(JSON.stringify(config), {
            headers: { 'Content-Type': 'application/json' }
        });
    }

    const headers = {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Cache-Control'
    };

    let currentStreamInfo: StreamInfo | null = null;

    const stream = new ReadableStream({
        start(controller) {
            let isStreamOpen = true;

            const streamInfo: StreamInfo = {
                controller,
                close: () => {
                    if (isStreamOpen) {
                        isStreamOpen = false;
                        try {
                            // Only close if controller is not already closed
                            if (controller.desiredSize !== null) {
                                controller.close();
                                console.log('GET: Stream closed');
                            } else {
                                console.log('GET: Stream was already closed');
                            }
                        } catch (error) {
                            console.error('GET: Error closing stream:', error);
                        }
                        activeStreams.delete(streamInfo);
                    }
                }
            };
            currentStreamInfo = streamInfo;
            activeStreams.add(streamInfo);
            console.log('GET: New SSE connection established. Active streams:', activeStreams.size);

            // Send current configurations immediately to new connections
            if (currentConfigurations.length > 0) {
                try {
                    const dataStr = JSON.stringify(currentConfigurations).replace(/\n/g, '');
                    const message = `data: ${dataStr}\n\n`;
                    console.log('GET: Sending initial data:', message.substring(0, 100) + '...');
                    controller.enqueue(new TextEncoder().encode(message));
                } catch (error) {
                    console.error('GET: Error sending initial data:', error);
                }
            } else {
                console.log('GET: No initial configurations to send');
            }

            return () => {
                console.log('GET: Cleaning up SSE stream');
                streamInfo.close();
            };
        },
        cancel() {
            console.log('GET: SSE client disconnected');
            if (currentStreamInfo) {
                currentStreamInfo.close();
            }
        }
    });

    return new Response(stream, { headers });
};

function isValidData(obj: any): obj is Data {
    return (
        obj &&
        Array.isArray(obj.nodes) &&
        obj.nodes.every(
            (node: any) => typeof node.id === 'number' && typeof node.title === 'string'
        ) &&
        Array.isArray(obj.edges) &&
        obj.edges.every(
            (edge: any) => typeof edge.source === 'number' && typeof edge.target === 'number'
        )
    );
}

function isValidConfigurations(obj: any): obj is DataConfiguration[] {
    return (
        Array.isArray(obj) &&
        obj.every((config: any) => 
            config &&
            typeof config.id === 'string' &&
            typeof config.title === 'string' &&
            isValidData(config.data)
        )
    );
}
