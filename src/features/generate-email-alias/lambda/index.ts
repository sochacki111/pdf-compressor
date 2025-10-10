import { APIGatewayEvent, Context } from 'aws-lambda';
import axios from 'axios';

const API_KEY = process.env.ADDY_API_KEY!;
const BASE_URL = process.env.BASE_URL!;

export const handler = async (event: APIGatewayEvent | any, context: Context) => {
    console.log("Generate Email Alias Event:", JSON.stringify(event, null, 2));
    console.log("Context:", JSON.stringify(context, null, 2));

    try {
        const requestPayload = {
            domain: 'anonaddy.com',
            format: 'random_characters' // Options: 'uuid', 'random_characters', 'custom', 'random_words'
        };

        console.log('API Request:', JSON.stringify({
            url: `${BASE_URL}/aliases`,
            payload: requestPayload,
            hasApiKey: !!API_KEY
        }, null, 2));

        const response = await axios.post(
            `${BASE_URL}/aliases`,
            requestPayload,
            { 
                headers: { 
                    'Authorization': `Bearer ${API_KEY}`,
                    'Content-Type': 'application/json',
                    'Accept': 'application/json'
                } 
            }
        );

        console.log('API Response:', JSON.stringify(response.data, null, 2));

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
        
        // Log detailed error information
        if (error.response) {
            console.error('API Error Status:', error.response.status);
            console.error('API Error Data:', JSON.stringify(error.response.data, null, 2));
            console.error('API Error Headers:', JSON.stringify(error.response.headers, null, 2));
        }
        
        return {
            statusCode: error.response?.status || 500,
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                error: 'Failed to create alias',
                message: error.message,
                details: error.response?.data,
                requestId: context.awsRequestId
            })
        };
    }
};
