/*
 Copyright 2019 The Matrix.org Foundation C.I.C

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXAggregatedReactionsUpdater.h"

#import "MXEventUnsignedData.h"
#import "MXEventRelations.h"
#import "MXEventAnnotationChunk.h"
#import "MXEventAnnotation.h"
#import "MXSession.h"

@interface MXAggregatedReactionsUpdater ()

@property (nonatomic) NSString *myUserId;
@property (nonatomic, weak) id<MXStore> matrixStore;
@property (nonatomic, weak) id<MXAggregationsStore> store;
@property (nonatomic, weak) MXSession *mxSession;
@property (nonatomic) NSMutableArray<MXReactionCountChangeListener*> *listeners;

@end

@implementation MXAggregatedReactionsUpdater

- (instancetype)initWithMatrixSession:(MXSession *)mxSession aggregationStore:(id<MXAggregationsStore>)aggregationStore
{
    self = [super init];
    if (self)
    {
        self.myUserId = mxSession.matrixRestClient.credentials.userId;
        self.store = aggregationStore;
        self.matrixStore = mxSession.store;
        self.mxSession = mxSession;

        self.listeners = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Data access

- (nullable MXAggregatedReactions *)aggregatedReactionsOnEvent:(NSString*)eventId inRoom:(NSString*)roomId
{
    // TODO: Use reaction count when API will be enabled
//    NSArray<MXReactionCount*> *reactions = [self.store reactionCountsOnEvent:eventId];
    NSArray<MXReactionCount*> *reactions;

    if (!reactions)
    {
        // Check reaction data from the hack
        reactions = [self reactionCountsUsingHackOnEvent:eventId inRoom:roomId];
    }

    MXAggregatedReactions *aggregatedReactions;
    if (reactions)
    {
        aggregatedReactions = [MXAggregatedReactions new];
        aggregatedReactions.reactions = reactions;
    }

    return aggregatedReactions;
}

- (nullable MXReactionCount*)reactionCountForReaction:(NSString*)reaction onEvent:(NSString*)eventId inRoom:(NSString*)roomId;
{
    return [self reactionCountsUsingHackOnEvent:eventId withReaction:reaction inRoom:roomId].firstObject;
}

#pragma mark - Data update listener

- (id)listenToReactionCountUpdateInRoom:(NSString *)roomId block:(void (^)(NSDictionary<NSString *,MXReactionCountChange *> * _Nonnull))block
{
    MXReactionCountChangeListener *listener = [MXReactionCountChangeListener new];
    listener.roomId = roomId;
    listener.notificationBlock = block;

    [self.listeners addObject:listener];

    return listener;
}

- (void)removeListener:(id)listener
{
    [self.listeners removeObject:listener];
}


#pragma mark - Data update

- (void)handleOriginalAggregatedDataOfEvent:(MXEvent *)event annotations:(MXEventAnnotationChunk*)annotations
{
    NSMutableArray *reactions;

    for (MXEventAnnotation *annotation in annotations.chunk)
    {
        if ([annotation.type isEqualToString:MXEventAnnotationReaction])
        {
            MXReactionCount *reactionCount = [MXReactionCount new];
            reactionCount.reaction = annotation.key;
            reactionCount.count = annotation.count;

            if (!reactions)
            {
                reactions = [NSMutableArray array];
            }
            [reactions addObject:reactionCount];
        }
    }

    if (reactions)
    {
        [self.store setReactionCounts:reactions onEvent:event.eventId inRoom:event.roomId];
    }
}


- (void)handleReaction:(MXEvent *)event direction:(MXTimelineDirection)direction
{
    NSString *parentEventId = event.relatesTo.eventId;
    NSString *reaction = event.relatesTo.key;
    
    if (parentEventId && reaction)
    {
        // TODO: Use reaction count when API will be enabled
//        // Manage aggregated reactions only for events in timelines we have
//        MXEvent *parentEvent = [self.matrixStore eventWithEventId:parentEventId inRoom:event.roomId];
//        if (parentEvent)
//        {
//            if (direction == MXTimelineDirectionForwards)
//            {
//                [self updateReactionCountForReaction:reaction toEvent:parentEventId reactionEvent:event];
//            }
//
//            [self storeRelationForReaction:reaction toEvent:parentEventId reactionEvent:event];
//        }
//        else
//        {
            [self storeRelationForHackForReaction:reaction toEvent:parentEventId reactionEvent:event];
//        }
    }
    else
    {
        NSLog(@"[MXAggregations] handleReaction: ERROR: invalid reaction event: %@", event);
    }
}

- (void)handleRedaction:(MXEvent *)event
{
    NSString *redactedEventId = event.redacts;
    MXReactionRelation *relation = [self.store reactionRelationWithReactionEventId:redactedEventId];

    if (relation)
    {
        [self.store deleteReactionRelation:relation];
        [self removeReaction:relation.reaction onEvent:relation.eventId inRoomId:event.roomId];
    }
}

- (void)resetDataInRoom:(NSString *)roomId
{
    [self.store deleteAllReactionCountsInRoom:roomId];
    [self.store deleteAllReactionRelationsInRoom:roomId];
}

#pragma mark - Private methods -

- (void)storeRelationForReaction:(NSString*)reaction toEvent:(NSString*)eventId reactionEvent:(MXEvent *)reactionEvent
{
    MXReactionRelation *relation = [MXReactionRelation new];
    relation.reaction = reaction;
    relation.eventId = eventId;
    relation.reactionEventId = reactionEvent.eventId;
    relation.senderId = reactionEvent.sender;

    [self.store addReactionRelation:relation inRoom:reactionEvent.roomId];
}

- (void)updateReactionCountForReaction:(NSString*)reaction toEvent:(NSString*)eventId reactionEvent:(MXEvent *)reactionEvent
{
    BOOL isANewReaction = NO;

    // Migrate data from matrix store to aggregation store if needed
    [self checkAggregationStoreWithHackForEvent:eventId inRoomId:reactionEvent.roomId];

    // Create or update the current reaction count if it exists
    MXReactionCount *reactionCount = [self.store reactionCountForReaction:reaction onEvent:eventId];
    if (!reactionCount)
    {
        // If we still have no reaction count object, create one
        reactionCount = [MXReactionCount new];
        reactionCount.reaction = reaction;
        isANewReaction = YES;
    }

    // Add the reaction
    reactionCount.count++;

    // Store reaction made by our user
    if ([reactionEvent.sender isEqualToString:self.myUserId])
    {
        reactionCount.myUserReactionEventId = reactionEvent.eventId;
    }

    // Update store
    [self.store addOrUpdateReactionCount:reactionCount onEvent:eventId inRoom:reactionEvent.roomId];

    // Notify
    [self notifyReactionCountChangeListenersOfRoom:reactionEvent.roomId
                                             event:eventId
                                     reactionCount:reactionCount
                                     isNewReaction:isANewReaction];
}

- (void)removeReaction:(NSString*)reaction onEvent:(NSString*)eventId inRoomId:(NSString*)roomId
{
    // Migrate data from matrix store to aggregation store if needed
    [self checkAggregationStoreWithHackForEvent:eventId inRoomId:roomId];

    // Create or update the current reaction count if it exists
    MXReactionCount *reactionCount = [self.store reactionCountForReaction:reaction onEvent:eventId];
    if (reactionCount)
    {
        if (reactionCount.count > 1)
        {
            reactionCount.count--;

            [self.store addOrUpdateReactionCount:reactionCount onEvent:eventId inRoom:roomId];
            [self notifyReactionCountChangeListenersOfRoom:roomId
                                                     event:eventId
                                             reactionCount:reactionCount
                                             isNewReaction:NO];
        }
        else
        {
            [self.store deleteReactionCountsForReaction:reaction onEvent:eventId];
            [self notifyReactionCountChangeListenersOfRoom:roomId event:eventId forDeletedReaction:reaction];
        }
    }
}

- (void)notifyReactionCountChangeListenersOfRoom:(NSString*)roomId event:(NSString*)eventId reactionCount:(MXReactionCount*)reactionCount isNewReaction:(BOOL)isNewReaction
{
    MXReactionCountChange *reactionCountChange = [MXReactionCountChange new];
    if (isNewReaction)
    {
        reactionCountChange.inserted = @[reactionCount];
    }
    else
    {
        reactionCountChange.modified = @[reactionCount];
    }

    [self notifyReactionCountChangeListenersOfRoom:roomId changes:@{
                                                                    eventId:reactionCountChange
                                                                    }];
}

- (void)notifyReactionCountChangeListenersOfRoom:(NSString*)roomId event:(NSString*)eventId forDeletedReaction:(NSString*)deletedReaction
{
    MXReactionCountChange *reactionCountChange = [MXReactionCountChange new];
    reactionCountChange.deleted = @[deletedReaction];

    [self notifyReactionCountChangeListenersOfRoom:roomId changes:@{
                                                                    eventId:reactionCountChange
                                                                    }];
}

- (void)notifyReactionCountChangeListenersOfRoom:(NSString*)roomId changes:(NSDictionary<NSString*, MXReactionCountChange*>*)changes
{
    for (MXReactionCountChangeListener *listener in self.listeners)
    {
        if ([listener.roomId isEqualToString:roomId])
        {
            listener.notificationBlock(changes);
        }
    }
}


#pragma mark - Reactions hack (TODO: Remove all methods) -
/// TODO: To remove once the feature has landed on matrix.org homeserver


//// If not already done, run the hack: build reaction count from known relations
- (void)checkAggregationStoreWithHackForEvent:(NSString*)eventId inRoomId:(NSString*)roomId
{
    if (![self.store hasReactionCountsOnEvent:eventId])
    {
        // Check reaction data from the hack
        NSArray<MXReactionCount*> *reactions = [self reactionCountsUsingHackOnEvent:eventId inRoom:roomId];

        if (reactions)
        {
            [self.store setReactionCounts:reactions onEvent:eventId inRoom:roomId];
        }
    }
}

- (nullable NSArray<MXReactionCount*> *)reactionCountsUsingHackOnEvent:(NSString*)eventId inRoom:(NSString*)roomId
{
    return [self reactionCountsUsingHackOnEvent:eventId withReaction:nil inRoom:roomId];
}

// Compute reactions counts from relations we know
// Note: This is not accurate and will be removed soon
- (nullable NSArray<MXReactionCount*> *)reactionCountsUsingHackOnEvent:(NSString*)eventId withReaction:(NSString*)reaction inRoom:(NSString*)roomId
{
    NSDate *startDate = [NSDate date];
    
    NSMutableDictionary<NSString*, MXReactionCount*> *reactionCountDict;
    
    NSMutableArray<MXReactionRelation*> *relations = [NSMutableArray new];
    
    NSArray<MXReactionRelation*> *remoteEchoesRelations;
    
    if (reaction)
    {
        remoteEchoesRelations = [self.store reactionRelationsOnEvent:eventId withReaction:reaction];
        
        for (MXReactionRelation *reactionRelation in [self.store reactionRelationsOnEvent:eventId])
        {
            NSLog(@"reaction: %@", reactionRelation.reaction);
        }
    }
    else
    {
        remoteEchoesRelations = [self.store reactionRelationsOnEvent:eventId];
    }
    
    if (remoteEchoesRelations)
    {
        [relations addObjectsFromArray:remoteEchoesRelations];
    }
    
    NSArray<MXReactionRelation*> *localEchoesRelations = [self localEchoesReactionRelationsOnEvent:eventId withReaction:reaction inRoom:roomId];
    
    if (localEchoesRelations)
    {
        [relations addObjectsFromArray:localEchoesRelations];
    }
    
    for (MXReactionRelation *relation in relations)
    {
        if (!reactionCountDict)
        {
            // Have the same behavior as reactionCountsFromMatrixStoreOnEvent
            reactionCountDict = [NSMutableDictionary dictionary];
        }
        
        MXReactionCount *reactionCount = reactionCountDict[relation.reaction];
        if (!reactionCount)
        {
            reactionCount = [MXReactionCount new];
            reactionCount.reaction = relation.reaction;
            reactionCountDict[relation.reaction] = reactionCount;
        }
        
        reactionCount.count++;
        
        if (!reactionCount.myUserReactionEventId)
        {
            // Determine if my user has reacted
            if ([relation.senderId isEqualToString:self.myUserId])
            {
                reactionCount.myUserReactionEventId = relation.reactionEventId;
            }
        }
    }
    
    NSLog(@"[MXAggregations] reactionCountsUsingHackOnEvent: Build %@ reactionCounts in %.0fms",
          @(reactionCountDict.count),
          [[NSDate date] timeIntervalSinceDate:startDate] * 1000);
    
    return reactionCountDict.allValues;
}

- (nullable NSArray<MXReactionRelation*> *)localEchoesReactionRelationsOnEvent:(NSString*)eventId inRoom:(NSString*)roomId
{
    return [self localEchoesReactionRelationsOnEvent:eventId withReaction:nil inRoom:roomId];
}

- (nullable NSArray<MXReactionRelation*> *)localEchoesReactionRelationsOnEvent:(NSString*)eventId withReaction:(NSString*)reaction inRoom:(NSString*)roomId
{
    MXRoom *room = [self.mxSession roomWithRoomId:roomId];
    NSArray *outgoingMessages = room.outgoingMessages;
    
    if (!outgoingMessages.count)
    {
        return nil;
    }
    
    NSMutableArray<MXReactionRelation*> *reactionRelations;
    
    for (MXEvent *localEchoEvent in outgoingMessages)
    {
        // Search for reaction event of current user. Filter with reaction string parameter if not nil.
        if ([localEchoEvent.sender isEqualToString:self.myUserId]
            && localEchoEvent.eventType == MXEventTypeReaction
            && [localEchoEvent.relatesTo.eventId isEqualToString:eventId]
            && (!reaction || [localEchoEvent.relatesTo.key isEqualToString:reaction]))
        {
            if (!reactionRelations)
            {
                reactionRelations = [NSMutableArray new];
            }
            
            MXReactionRelation *reactionRelation = [MXReactionRelation new];
            reactionRelation.eventId = eventId;
            reactionRelation.reaction = localEchoEvent.relatesTo.key;
            reactionRelation.reactionEventId = localEchoEvent.eventId;
            reactionRelation.senderId = localEchoEvent.sender;
            
            [reactionRelations addObject:reactionRelation];
        }
    }
    
    return [reactionRelations copy];
}

// We need to store all received relations even if we do not know the event yet
- (void)storeRelationForHackForReaction:(NSString*)reaction toEvent:(NSString*)eventId reactionEvent:(MXEvent *)reactionEvent
{
    [self storeRelationForReaction:reaction toEvent:eventId reactionEvent:reactionEvent];
}

@end
