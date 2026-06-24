/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   driver.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:49:44 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:49:45 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package outboxrelay

import (
	"context"

	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// driverDB adapts a *mongo.Database to the narrow mongoClient seam.
type driverDB struct{ db *mongo.Database }

func (d driverDB) updateOne(ctx context.Context, coll string, filter, update any, upsert bool) error {
	_, err := d.db.Collection(coll).UpdateOne(ctx, filter, update, options.Update().SetUpsert(upsert))
	return err
}

func (d driverDB) deleteOne(ctx context.Context, coll string, filter any) error {
	_, err := d.db.Collection(coll).DeleteOne(ctx, filter)
	return err
}
