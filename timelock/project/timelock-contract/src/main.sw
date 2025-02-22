contract;

dep data_structures;
dep errors;
dep events;
dep interface;
dep utils;

use data_structures::ExecutionRange;
use errors::{AccessControlError, FundingError, TransactionError};
use events::{CancelEvent, ExecuteEvent, QueueEvent};
use interface::{Info, Timelock};
use std::{
    auth::msg_sender,
    block::timestamp as now,
    bytes::Bytes,
    call_frames::msg_asset_id,
    context::this_balance,
    logging::log,
};
use utils::create_hash;

const ADMIN: Identity = Identity::Address(Address::from(OWNER));

storage {
    /// Mapping transaction hash to time range of available execution
    queue: StorageMap<b256, Option<ExecutionRange>> = StorageMap {},
}

impl Timelock for Contract {
    #[storage(read, write)]
    fn cancel(id: b256) {
        require(msg_sender().unwrap() == ADMIN, AccessControlError::AuthorizationError);
        require(storage.queue.get(id).is_some(), TransactionError::InvalidTransaction(id));

        storage.queue.insert(id, Option::None::<ExecutionRange>());

        log(CancelEvent { id })
    }

    #[storage(read, write)]
    fn execute(
        recipient: Identity,
        value: Option<u64>,
        asset_id: Option<ContractId>,
        data: Bytes,
        timestamp: u64,
    ) {
        require(msg_sender().unwrap() == ADMIN, AccessControlError::AuthorizationError);

        let id = create_hash(recipient, value, asset_id, data, timestamp);
        let transaction = storage.queue.get(id);

        require(transaction.is_some(), TransactionError::InvalidTransaction(id));

        // Timestamp is guarenteed to be in the range because of `fn queue()`
        // Therefore, the lower bound can be the timestamp itself; but, we must place an upper bound
        // to prevent going over the MAXIMUM_DELAY
        require(timestamp <= now() && now() <= transaction.unwrap().end, TransactionError::TimestampNotInRange((timestamp, transaction.unwrap().end, now())));

        if value.is_some() {
            require(value.unwrap() <= this_balance(asset_id.unwrap()), FundingError::InsufficientContractBalance((this_balance(asset_id.unwrap()))));
        }

        storage.queue.insert(id, Option::None::<ExecutionRange>());

        // TODO: execute arbitrary call...
        log(ExecuteEvent {
            asset_id,
            data,
            id,
            recipient,
            timestamp,
            value,
        })
    }

    #[storage(read, write)]
    fn queue(
        recipient: Identity,
        value: Option<u64>,
        asset_id: Option<ContractId>,
        data: Bytes,
        timestamp: u64,
    ) {
        require(msg_sender().unwrap() == ADMIN, AccessControlError::AuthorizationError);

        let id = create_hash(recipient, value, asset_id, data, timestamp);
        let transaction = storage.queue.get(id);

        require(transaction.is_none(), TransactionError::DuplicateTransaction(id));

        let start = now() + MINIMUM_DELAY;
        let end = now() + MAXIMUM_DELAY;

        require(start <= timestamp && timestamp <= end, TransactionError::TimestampNotInRange((start, end, timestamp)));

        storage.queue.insert(id, Option::Some(ExecutionRange { start, end }));

        log(QueueEvent {
            asset_id,
            data,
            id,
            recipient,
            timestamp,
            value,
        })
    }
}

impl Info for Contract {
    fn balance(asset_id: ContractId) -> u64 {
        this_balance(asset_id)
    }

    fn delays() -> (u64, u64) {
        (MINIMUM_DELAY, MAXIMUM_DELAY)
    }

    #[storage(read)]
    fn queued(id: b256) -> Option<ExecutionRange> {
        storage.queue.get(id)
    }

    fn transaction_hash(
        recipient: Identity,
        value: Option<u64>,
        asset_id: Option<ContractId>,
        data: Bytes,
        timestamp: u64,
    ) -> b256 {
        create_hash(recipient, value, asset_id, data, timestamp)
    }
}
