import type { RequestHandler } from '@sveltejs/kit';
import { EventEmitter } from 'events';

const messages: string[] = [];
const emitter = new EventEmitter();

export const POST: RequestHandler = async ({ request }) => {
    try {
        const rawBody = await request.text();

        let data;
        try {
            data = JSON.parse(rawBody);
        } catch (parseError: any) {
            console.error('JSON parse error:', parseError);
            return new Response(JSON.stringify({ error: 'Invalid JSON', details: parseError.message }), {
                status: 400,
                headers: { 'Content-Type': 'application/json' }
            });
        }

        const { message } = data;
        if (!message || typeof message !== 'string') {
            return new Response(JSON.stringify({ error: 'Valid message string is required' }), {
                status: 400,
                headers: { 'Content-Type': 'application/json' }
            });
        }

        messages.push(message);

        try {
            emitter.emit('message', message);
        } catch (emitError) {
            console.error('Error emitting message:', emitError);
        }

        return new Response(JSON.stringify({ status: 'Message received' }), {
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
            messages.forEach((msg) => {
                try {
                    controller.enqueue(`data: ${JSON.stringify({ message: msg })}\n\n`);
                } catch (error) {
                    console.error('Error enqueuing initial message:', error);
                    controller.close();
                    return;
                }
            });

            const listener = (message: string) => {
                try {
                    controller.enqueue(`data: ${JSON.stringify({ message })}\n\n`);
                } catch (error) {
                    console.error('Error enqueuing message:', error);
                    controller.close();
                    emitter.off('message', listener); 
                }
            };
            emitter.on('message', listener);

            return () => {
                emitter.off('message', listener);
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