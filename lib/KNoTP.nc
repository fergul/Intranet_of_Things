#include <stdlib.h>
#include "KNoT.h"
#if DEBUG
#include "printf.h"
#define PRINTF(...) printf(__VA_ARGS__)
#define PRINTFFLUSH(...) printfflush()
#elif SIM
#define PRINTF(...) dbg("DEBUG",__VA_ARGS__)
#define PRINTFFLUSH(...)
#else  
#define PRINTF(...)
#define PRINTFFLUSH(...)
#endif

#define SEQNO_START 0
#define SEQNO_LIMIT 255
#ifndef DEVICE_NAME
#define DEVICE_NAME "WHOAMI"
#endif
#ifndef SENSOR_TYPE
#define SENSOR_TYPE 0
#endif
#ifndef DATA_RATE
#define DATA_RATE 10
#endif

module KNoTP @safe() {
	provides interface KNoT;
	uses {
		interface Boot;
	    interface AMPacket;
        interface Receive;
        interface AMSend;
        interface SplitControl as RadioControl;
        interface LEDBlink;
	}
}
implementation {
	message_t am_pkt;
	message_t serial_pkt;
	bool serialSendBusy = FALSE;
	bool sendBusy = FALSE;

	void increment_seq_no(ChanState *state, DataPayload *dp){
		if (state->seqno >= SEQNO_LIMIT){
			state->seqno = SEQNO_START;
		} else {
			state->seqno++;
		}
		dp->hdr.seqno = state->seqno;
	}
	
	void send(int dest, DataPayload *dp){
		uint8_t len = sizeof(PayloadHeader) + sizeof(DataHeader) + dp->dhdr.tlen;
		DataPayload *payload = (DataPayload *) (call AMSend.getPayload(&am_pkt, sizeof(DataPayload)));
		memcpy(payload, dp, sizeof(DataPayload));
		//call AMPacket.setSource(&am_pkt, call AMPacket.address());
		if (call AMSend.send(dest, &am_pkt, len) == SUCCESS) {
			sendBusy = TRUE;
			PRINTF("RADIO>> Sent a %s packet to Thing %d\n", cmdnames[dp->hdr.cmd], dest);		
			PRINTF("RADIO>> KNoT Payload Length: %d\n", dp->dhdr.tlen);
		}
		else {
			PRINTF("ID: %d, Radio Msg could not be sent, channel busy\n", TOS_NODE_ID);
			call LEDBlink.report_problem();
		}
		PRINTFFLUSH();
	}

	void dp_complete(DataPayload *dp, uint8_t src, uint8_t dst, 
	             uint8_t cmd, uint8_t len){
		dp->hdr.src_chan_num = src; 
		dp->hdr.dst_chan_num = dst; 
		dp->hdr.cmd = cmd; 
		dp->dhdr.tlen = len;
	}

	command int KNoT.valid_seqno(ChanState *state, DataPayload *dp){
		if (state->seqno > dp->hdr.seqno){ // Old packet or sender confused
			return 0;
		} else {
			state->seqno = dp->hdr.seqno;
			if (state->seqno >= SEQNO_LIMIT){
				state->seqno = SEQNO_START;
			}
			return 1;
		}
	}

	command void KNoT.send_on_chan(ChanState *state, DataPayload *dp){
		increment_seq_no(state, dp);
		send(state->remote_addr, dp);
	}

	command void KNoT.knot_broadcast(ChanState *state, DataPayload *dp){
		increment_seq_no(state, dp);
		send(AM_BROADCAST_ADDR, dp);
	}


/* Higher level calls */

/***** QUERY CALLS AND HANDLERS ******/
	command void KNoT.query(ChanState* state, uint8_t type){
		DataPayload *new_dp = &(state->packet); 
		QueryMsg *q;
	    clean_packet(new_dp);
	    dp_complete(new_dp, HOME_CHANNEL, HOME_CHANNEL, 
	             QUERY, sizeof(QueryMsg));
	    q = (QueryMsg *) new_dp->data;
	    q->type = type;
	    strcpy((char*)q->name, DEVICE_NAME);
	    call KNoT.knot_broadcast(state, new_dp);
	    set_ticks(state, TICKS);
	    set_state(state, STATE_QUERY);
	    // Set timer to exit Query state after 5 secs~
	}

	command void KNoT.query_handler(ChanState *state, DataPayload *dp, uint8_t src){
		DataPayload *new_dp;
		QueryResponseMsg *qr;
		QueryMsg *q = (QueryMsg*)(dp->data);
		if (q->type != SENSOR_TYPE) {
			PRINTF("Query doesn't match type\n");
			return;
		}
		PRINTF("Query matches type\n");
		state->remote_addr = src;
		new_dp = &(state->packet);
		qr = (QueryResponseMsg*)&(new_dp->data);
		clean_packet(new_dp);
		strcpy((char*)qr->name, DEVICE_NAME); /* copy name */
		qr->type = SENSOR_TYPE;
		qr->rate = DATA_RATE;
		dp_complete(new_dp, state->chan_num, dp->hdr.src_chan_num, 
					QACK, sizeof(QueryResponseMsg));
		call KNoT.send_on_chan(state, new_dp);
	}

	command void KNoT.qack_handler(ChanState *state, DataPayload *dp, uint8_t src) {
		SerialQueryResponseMsg *qr;
		if (state->state != STATE_QUERY) {
			PRINTF("KNOT>> Not in Query state\n");
			return;
		}
	    state->remote_addr = src; 
		//qr = (SerialQueryResponseMsg *) &dp->data;
		//qr->src = state->remote_addr;
		//send_on_serial(dp);
	}

/*********** CONNECT CALLS AND HANDLERS ********/
	
	command void KNoT.connect(ChanState *state, uint8_t addr, int rate){
		ConnectMsg *cm;
		DataPayload *new_dp;
		state->remote_addr = addr;
		state->rate = rate;
		new_dp = &(state->packet);
		clean_packet(new_dp);
		dp_complete(new_dp, state->chan_num, HOME_CHANNEL, 
	             CONNECT, sizeof(ConnectMsg));
		cm = (ConnectMsg *)(new_dp->data);
		cm->rate = rate;
	    call KNoT.send_on_chan(state, new_dp);
	    set_ticks(state, TICKS);
	    set_attempts(state, ATTEMPTS);
	    set_state(state, STATE_CONNECT);
	   	PRINTF("KNOT>> Sent connect request from chan %d\n", state->chan_num);
	    PRINTFFLUSH();
		
	}

	command void KNoT.connect_handler(ChanState *state, DataPayload *dp, uint8_t src){
		ConnectMsg *cm;
		DataPayload *new_dp;
		ConnectACKMsg *ck;
		state->remote_addr = src;
		cm = (ConnectMsg*)dp->data;
		/* Request src must be saved to message back */
		state->remote_chan_num = dp->hdr.src_chan_num;
		if (cm->rate > DATA_RATE) state->rate = cm->rate;
		else state->rate = DATA_RATE;
		new_dp = &(state->packet);
		ck = (ConnectACKMsg *)&(new_dp->data);
		clean_packet(new_dp);
		dp_complete(new_dp, state->chan_num, state->remote_chan_num, 
					CACK, sizeof(ConnectACKMsg));
		ck->accept = 1;
		call KNoT.send_on_chan(state, new_dp);
		set_ticks(state, TICKS);
		set_attempts(state, ATTEMPTS);
		set_state(state, STATE_CONNECT);
		PRINTF("KNOT>> %d wants to connect from channel %d\n", src, state->remote_chan_num);
		PRINTFFLUSH();
		PRINTF("KNOT>> Replying on channel %d\n", state->chan_num);
		PRINTF("KNOT>> The rate is set to: %d\n", state->rate);
		PRINTFFLUSH();
	}

	command uint8_t KNoT.controller_cack_handler(ChanState *state, DataPayload *dp){
		ConnectACKMsg *ck = (ConnectACKMsg*)(dp->data);
		DataPayload *new_dp;
		SerialConnectACKMsg *sck;
		if (state->state != STATE_CONNECT){
			PRINTF("KNOT>> Not in Connecting state\n");
			return -1;
		}
		if (ck->accept == 0){
			PRINTF("KNOT>> SCREAM! THEY DIDN'T EXCEPT!!\n");
			return 0;
		}
		PRINTF("KNOT>> %d accepts connection request on channel %d\n", 
			state->remote_addr,
			dp->hdr.src_chan_num);PRINTFFLUSH();
		state->remote_chan_num = dp->hdr.src_chan_num;
		new_dp = &(state->packet);
		clean_packet(new_dp);
		dp_complete(new_dp, state->chan_num, state->remote_chan_num, 
	             CACK, NO_PAYLOAD);
		call KNoT.send_on_chan(state,new_dp);
		set_ticks(state, ticks_till_ping(state->rate));
		set_attempts(state, ATTEMPTS);
		set_state(state, STATE_CONNECTED);
		//Set up ping timeouts for liveness if no message received or
		// connected to actuator
		//sck = (SerialConnectACKMsg *) ck;
		//sck->src = state->remote_addr;
		//send_on_serial(dp);
		return 1;
	}

	command uint8_t KNoT.sensor_cack_handler(ChanState *state, DataPayload *dp){
		if (state->state != STATE_CONNECT){
			PRINTF("KNOT>> Not in Connecting state\n");
			return 0;
		}
		set_ticks(state, ticks_till_ping(state->rate));
		PRINTF("KNOT>> TX rate: %d\n", state->rate);
		PRINTF("KNOT>> CONNECTION FULLY ESTABLISHED<<\n");PRINTFFLUSH();
		set_state(state, STATE_CONNECTED);
		return 1;
	}

/**** RESPONSE CALLS AND HANDLERS ***/
	command void KNoT.send_value(ChanState *state, uint8_t *data, uint8_t len){
	    DataPayload *new_dp = &(state->packet);
		ResponseMsg *rmsg = (ResponseMsg*)&(new_dp->data);
		// Send a Response SYN or Response
		if (state->state == STATE_CONNECTED){
			clean_packet(new_dp);
			new_dp->hdr.cmd = RESPONSE;
	    	state->ticks_till_ping--;
	    } else if(state->state == STATE_RSYN){
	    	clean_packet(new_dp);
		    new_dp->hdr.cmd = RSYN; // Send to ensure controller is still out there
		    state->ticks_till_ping = RSYN_RATE;
		    set_state(state, STATE_RACK_WAIT);
	    } else if (state->state == STATE_RACK_WAIT){
	    	return; /* Waiting for response, no more sensor sends */
	    }
	    memcpy(&(rmsg->data), data, len);
	    new_dp->hdr.src_chan_num = state->chan_num;
		new_dp->hdr.dst_chan_num = state->remote_chan_num;
	    new_dp->dhdr.tlen = sizeof(ResponseMsg);
	    PRINTF("Sending data\n");
	    call KNoT.send_on_chan(state, new_dp);
	}

	command void KNoT.response_handler(ChanState *state, DataPayload *dp){
		ResponseMsg *rmsg;
		SerialResponseMsg *srmsg;
		uint8_t temp;
		if (state->state != STATE_CONNECTED && state->state != STATE_PING){
			PRINTF("KNOT>> Not connected to device!\n");
			return;
		}
		set_ticks(state, ticks_till_ping(state->rate)); /* RESET PING TIMER */
		set_attempts(state, ATTEMPTS);
		rmsg = (ResponseMsg *)dp->data;
		memcpy(&temp, &(rmsg->data), 1);
		PRINTF("KNOT>> Data rvd: %d\n", temp);
		PRINTF("Temp: %d\n", temp);
		//srmsg = (SerialResponseMsg *)dp->data;
		//srmsg->src = state->remote_addr;
		//send_on_serial(dp);
	}

	command void KNoT.send_rack(ChanState *state){
		DataPayload *new_dp = &(state->packet);
		clean_packet(new_dp);
		dp_complete(new_dp, state->chan_num, state->remote_chan_num, 
	             RACK, NO_PAYLOAD);
		call KNoT.send_on_chan(state, new_dp);
	}
	command void KNoT.rack_handler(ChanState *state, DataPayload *dp){
		if (state->state != STATE_RACK_WAIT){
			PRINTF("KNOT>> Didn't ask for a RACK!\n");
			return;
		}
		set_state(state, STATE_CONNECTED);
		set_ticks(state, ticks_till_ping(state->rate));
		set_attempts(state, ATTEMPTS);
	}

/*** PING CALLS AND HANDLERS ***/
	command void KNoT.ping(ChanState *state){
		DataPayload *new_dp = &(state->packet);
		clean_packet(new_dp);
		dp_complete(new_dp, state->chan_num, state->remote_chan_num, 
		           PING, NO_PAYLOAD);
		call KNoT.send_on_chan(state, new_dp);
		set_state(state, STATE_PING);
	}

	command void KNoT.ping_handler(ChanState *state, DataPayload *dp){
		DataPayload *new_dp;
		if (state->state != STATE_CONNECTED) {
			PRINTF("KNOT>> Not in Connected state\n");
			return;
		}
		new_dp = &(state->packet);
		clean_packet(new_dp);
		dp_complete(new_dp, state->chan_num, state->remote_chan_num, 
		           PACK, NO_PAYLOAD);
		call KNoT.send_on_chan(state,new_dp);
	}

	command void KNoT.pack_handler(ChanState *state, DataPayload *dp){
		if (state->state != STATE_PING) {
			PRINTF("KNOT>> Not in PING state\n");
			return;
		}
		set_state(state, STATE_CONNECTED);
		set_ticks(state, ticks_till_ping(state->rate));
		set_attempts(state, ATTEMPTS);
	}

/*** DISCONNECT CALLS AND HANDLERS ***/
	command void KNoT.close_graceful(ChanState *state){
		DataPayload *new_dp = &(state->packet);
		clean_packet(new_dp);
		dp_complete(new_dp, state->chan_num, state->remote_chan_num, 
		           DISCONNECT, NO_PAYLOAD);
		call KNoT.send_on_chan(state,new_dp);
		set_state(state, STATE_DCONNECTED);
	}
	command void KNoT.disconnect_handler(ChanState *state, DataPayload *dp){
		DataPayload *new_dp = &(state->packet);
		clean_packet(new_dp);
		dp_complete(new_dp, dp->hdr.src_chan_num, state->remote_chan_num, 
	               DACK, NO_PAYLOAD);
		call KNoT.send_on_chan(state, new_dp);
	}


/*--------------------------- EVENTS ------------------------------------------------*/
   event void Boot.booted() {
        if (call RadioControl.start() != SUCCESS) {
        	PRINTF("RADIO>> ERROR BOOTING RADIO\n");
        	PRINTFFLUSH();
        }
    }

/*-----------Radio & AM EVENTS------------------------------- */
    event void RadioControl.startDone(error_t error) {
    	PRINTF("*********************\n*** RADIO BOOTED ****\n*********************\n");
    	PRINTF("RADIO>> ADDR: %d\n", call AMPacket.address());
        PRINTFFLUSH();
    }

    event void RadioControl.stopDone(error_t error) {}
	
	event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
		return signal KNoT.receive(call AMPacket.source(msg), msg, payload, len);
	}

    event void AMSend.sendDone(message_t* msg, error_t error) {
        if (error == SUCCESS) {
        	call LEDBlink.report_sent();
        	PRINTF("RADIO>> Packet sent successfully\n");
        } else call LEDBlink.report_problem();
        sendBusy = FALSE;
    }



}