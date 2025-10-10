import { Context } from 'aws-lambda';
import axios from 'axios';

const AUCHAN_API_URL = process.env.AUCHAN_API_URL!;
const AUCHAN_API_KEY = process.env.AUCHAN_API_KEY!;

interface SubscribeAuchanInput {
    email: string;
}

export const handler = async (event: SubscribeAuchanInput, context: Context) => {
    console.log("Subscribe Auchan Newsletter Event:", JSON.stringify(event, null, 2));
    console.log("Context:", JSON.stringify(context, null, 2));

    try {
        const { email } = event;
        
        if (!email) {
            throw new Error('Email is required');
        }

        const requestPayload = {
            email: email,
            subscriptions: [
                "SUBSCRIPTION_TYPE_EMAIL_STORE"
            ],
            newsletters: [
                {
                    code: "SUBSCRIPTION_TYPE_EMAIL_STORE"
                }
            ]
        };

        console.log('Auchan API Request:', JSON.stringify({
            url: AUCHAN_API_URL,
            payload: requestPayload
        }, null, 2));

        const response = await axios.post(
            AUCHAN_API_URL,
            requestPayload,
            {
                headers: {
                    'X-Gravitee-Api-Key': AUCHAN_API_KEY,
                    'Content-Type': 'application/json',
                    'Accept': 'application/json'
                }
            }
        );

        console.log('Auchan API Response:', JSON.stringify(response.data, null, 2));

        return {
            statusCode: 200,
            message: 'Successfully subscribed to Auchan newsletter',
            email: email,
            auchanResponse: response.data,
            requestId: context.awsRequestId
        };
    } catch (error: any) {
        console.error('Error subscribing to Auchan newsletter:', error);
        
        // Log detailed error information
        if (error.response) {
            console.error('Auchan API Error Status:', error.response.status);
            console.error('Auchan API Error Data:', JSON.stringify(error.response.data, null, 2));
            console.error('Auchan API Error Headers:', JSON.stringify(error.response.headers, null, 2));
        }
        
        throw new Error(`Failed to subscribe to Auchan newsletter: ${error.message}`);
    }
};



