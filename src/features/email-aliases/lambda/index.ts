import { APIGatewayEvent, Context } from 'aws-lambda';
import axios from 'axios';

const API_KEY = process.env.ADDY_API_KEY!;
const BASE_URL = 'https://app.addy.io/api/v1';

export const handler = async (event: APIGatewayEvent, context: Context) => {
    console.log("Email Aliases Event:", JSON.stringify(event, null, 2));
    console.log("Context:", JSON.stringify(context, null, 2));

    try {
        const { alias } = JSON.parse(event.body || '{}');
        if (!alias) {
            return {
                statusCode: 400,
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({ error: 'Alias is required' })
            };
        }

        const response = await axios.post(
            `${BASE_URL}/aliases`,
            { alias },
            { headers: { Authorization: `Bearer ${API_KEY}` } }
        );

        return {
            statusCode: 200,
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                message: 'Alias created successfully',
                alias: response.data,
                requestId: context.awsRequestId
            })
        };
    } catch (error: any) {
        console.error('Error creating alias:', error);
        
        return {
            statusCode: 500,
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                error: 'Failed to create alias',
                message: error.message,
                requestId: context.awsRequestId
            })
        };
    }
};
