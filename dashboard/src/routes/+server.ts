import type { RequestHandler } from '@sveltejs/kit';
import type { Data, Node, Edge } from '$lib';

var currentData: Data = { nodes: [], edges: [] };

const activeStreams: Set<{
    controller: ReadableStreamDefaultController;
    close: () => void;
}> = new Set();

export const POST: RequestHandler = async ({ request }) => {
    try {
        const rawBody = await request.text();
        let data;
        try {
            data = JSON.parse(rawBody);
            if (!isValidData(data)) {
                return new Response(JSON.stringify({ error: 'Invalid Data format' }), {
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

        currentData = {nodes: [], edges: []}

        currentData = {
            nodes: [...currentData.nodes.filter(n => !data.nodes.some(nn => nn.id === n.id)), ...data.nodes],
            edges: [...currentData.edges.filter(e => !data.edges.some(ne => ne.source === e.source && ne.target === e.target)), ...data.edges]
        };

        console.log('POST: Updated currentData:', currentData);

        for (const stream of activeStreams) {
            try {
                const message = `data: ${JSON.stringify(currentData)}\n\n`;
                stream.controller.enqueue(message);
                console.log('POST: Sent SSE update to stream:', currentData);
            } catch (error) {
                console.error('POST: Error sending SSE update to stream:', error);
                stream.close();
                activeStreams.delete(stream);
            }
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

export const GET: RequestHandler = async () => {
    const headers = {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive'
    };

    const stream = new ReadableStream({
        start(controller) {
            console.log('GET: SSE stream started');

            try {
                const initialMessage = `data: ${JSON.stringify(currentData)}\n\n`;
                controller.enqueue(initialMessage);
                console.log('GET: Sent initial data:', currentData);
            } catch (error) {
                console.error('GET: Error sending initial data:', error);
                controller.close();
                return;
            }

            let isStreamOpen = true;

            const streamInfo = {
                controller,
                close: () => {
                    if (isStreamOpen) {
                        isStreamOpen = false;
                        try {
                            controller.close();
                            console.log('GET: Stream closed');
                        } catch (error) {
                            console.error('GET: Error closing stream:', error);
                        }
                        activeStreams.delete(streamInfo);
                    }
                }
            };
            activeStreams.add(streamInfo);

            const pingInterval = setInterval(() => {
                if (!isStreamOpen) {
                    clearInterval(pingInterval);
                    return;
                }
                try {
                    controller.enqueue(':ping\n\n');
                    console.log('GET: Sent ping');
                } catch (error) {
                    console.error('GET: Error sending ping:', error);
                    streamInfo.close();
                }
            }, 5000); 

            return () => {
                console.log('GET: Cleaning up SSE stream');
                clearInterval(pingInterval);
                streamInfo.close();
            };
        },
        cancel() {
            console.log('GET: SSE client disconnected');
        }
    });

    return new Response(stream, { headers });
};

function isValidData(obj: any): obj is Data {
    return (
        obj &&
        Array.isArray(obj.nodes) &&
        obj.nodes.every(
            (node: any) => typeof node.id === 'string' && typeof node.title === 'string'
        ) &&
        Array.isArray(obj.edges) &&
        obj.edges.every(
            (edge: any) => typeof edge.source === 'string' && typeof edge.target === 'string'
        )
    );
}
