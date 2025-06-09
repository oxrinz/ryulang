import type { RequestHandler } from '@sveltejs/kit';
import { EventEmitter } from 'events';
import type { Data, Node, Edge } from '$lib'; 

let currentData: Data = { nodes: [], edges: [] };
const emitter = new EventEmitter();

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
            console.error('JSON parse error:', parseError);
            return new Response(JSON.stringify({ error: 'Invalid JSON', details: parseError.message }), {
                status: 400,
                headers: { 'Content-Type': 'application/json' }
            });
        }

        currentData = {
            nodes: [...currentData.nodes.filter(n => !data.nodes.some(nn => nn.id === n.id)), ...data.nodes],
            edges: [...currentData.edges.filter(e => !data.edges.some(ne => ne.source === e.source && ne.target === e.target)), ...data.edges]
        };

        try {
            emitter.emit('data', currentData);
        } catch (emitError) {
            console.error('Error emitting data:', emitError);
        }

        return new Response(JSON.stringify({ status: 'Data received' }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
        });
    } catch (error: any) {
        console.error('Unexpected error in POST handler:', error);
        return new Response(JSON.stringify({ error: 'Server error', details: error.message }), {
            status: 500,
            headers: { 'Content-Type': 'application/json' }
        });
    }
};

export const GET: RequestHandler = async ({ setHeaders }) => {
    setHeaders({
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive'
    });

    const stream = new ReadableStream({
        start(controller) {
            console.log('SSE stream started');

            try {
                controller.enqueue(`data: ${JSON.stringify(currentData)}\n\n`);
            } catch (error) {
                console.error('Error enqueuing initial data:', error);
                controller.close();
                return;
            }

            const listener = (data: Data) => {
                try {
                    controller.enqueue(`data: ${JSON.stringify(data)}\n\n`);
                } catch (error) {
                    console.error('Error enqueuing data:', error);
                    controller.close();
                    emitter.off('data', listener);
                }
            };
            emitter.on('data', listener);

            return () => {
                emitter.off('data', listener);
                console.log('SSE stream closed');
            };
        },
        cancel() {
            console.log('SSE client disconnected');
        }
    });

    return new Response(stream, {
        headers: { 'Content-Type': 'text/event-stream' }
    });
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