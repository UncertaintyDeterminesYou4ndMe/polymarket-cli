use anyhow::Result;
use clap::{Args, Subcommand};
use polymarket_client_sdk::gamma::{
    self,
    types::request::{
        EventsRequest, RelatedTagsByIdRequest, RelatedTagsBySlugRequest, TagByIdRequest,
        TagBySlugRequest, TagsRequest,
    },
};

use super::is_numeric_id;
use crate::output::OutputFormat;
use crate::output::tags::{print_related_tags, print_tag, print_tags, print_tags_with_stats};

#[derive(Args)]
pub struct TagsArgs {
    #[command(subcommand)]
    pub command: TagsCommand,
}

#[derive(Subcommand)]
pub enum TagsCommand {
    /// List tags
    List {
        /// Max results
        #[arg(long, default_value = "25")]
        limit: i32,

        /// Pagination offset
        #[arg(long)]
        offset: Option<i32>,

        /// Sort ascending instead of descending
        #[arg(long)]
        ascending: bool,

        /// Include statistics (market count, total volume) for each tag
        #[arg(long)]
        with_stats: bool,
    },

    /// List tags sorted by total market volume (highest first)
    Popular {
        /// Max results
        #[arg(long, default_value = "10")]
        limit: i32,

        /// Only include tags with active markets
        #[arg(long)]
        active_only: bool,
    },

    /// Get a single tag by ID or slug
    Get {
        /// Tag ID or slug
        id: String,
    },

    /// Get related tag relationships for a tag
    Related {
        /// Tag ID or slug
        id: String,

        /// Omit empty related tags
        #[arg(long)]
        omit_empty: Option<bool>,
    },

    /// Get actual tag objects related to a tag
    RelatedTags {
        /// Tag ID or slug
        id: String,

        /// Omit empty related tags
        #[arg(long)]
        omit_empty: Option<bool>,
    },
}

pub async fn execute(client: &gamma::Client, args: TagsArgs, output: OutputFormat) -> Result<()> {
    match args.command {
        TagsCommand::List {
            limit,
            offset,
            ascending,
            with_stats,
        } => {
            let request = TagsRequest::builder()
                .limit(limit)
                .maybe_offset(offset)
                .ascending(ascending)
                .build();

            let tags = client.tags(&request).await?;

            if with_stats {
                // Fetch stats for each tag
                let mut tag_stats = Vec::new();
                for tag in &tags {
                    if let Some(slug) = &tag.slug {
                        let events_req = EventsRequest::builder()
                            .limit(100)
                            .maybe_closed(Some(false))
                            .maybe_tag_slug(Some(slug.clone()))
                            .build();

                        if let Ok(events) = client.events(&events_req).await {
                            let market_count: usize = events
                                .iter()
                                .map(|e| e.markets.as_ref().map(|m| m.len()).unwrap_or(0))
                                .sum();

                            let total_volume: f64 = events
                                .iter()
                                .filter_map(|e| {
                                    e.volume.as_ref().and_then(|v| v.to_string().parse::<f64>().ok())
                                })
                                .sum();

                            tag_stats.push((tag.clone(), market_count, total_volume));
                        } else {
                            tag_stats.push((tag.clone(), 0, 0.0));
                        }
                    }
                }

                print_tags_with_stats(&tag_stats, &output)?;
            } else {
                print_tags(&tags, &output)?;
            }
        }

        TagsCommand::Popular {
            limit,
            active_only,
        } => {
            // Fetch all tags first
            let request = TagsRequest::builder().limit(100).build();
            let tags = client.tags(&request).await?;

            // Calculate stats for each tag
            let mut tag_stats = Vec::new();
            for tag in &tags {
                if let Some(slug) = &tag.slug {
                    let events_req = EventsRequest::builder()
                        .limit(100)
                        .maybe_closed(if active_only { Some(false) } else { None })
                        .maybe_tag_slug(Some(slug.clone()))
                        .build();

                    if let Ok(events) = client.events(&events_req).await {
                        let market_count: usize = events
                            .iter()
                            .map(|e| e.markets.as_ref().map(|m| m.len()).unwrap_or(0))
                            .sum();

                        let total_volume: f64 = events
                            .iter()
                            .filter_map(|e| {
                                e.volume.as_ref().and_then(|v| v.to_string().parse::<f64>().ok())
                            })
                            .sum();

                        // Only include tags with actual markets
                        if market_count > 0 {
                            tag_stats.push((tag.clone(), market_count, total_volume));
                        }
                    }
                }
            }

            // Sort by total volume descending
            tag_stats.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));

            // Apply limit
            tag_stats.truncate(limit as usize);

            print_tags_with_stats(&tag_stats, &output)?;
        }

        TagsCommand::Get { id } => {
            let is_numeric = is_numeric_id(&id);
            let tag = if is_numeric {
                let req = TagByIdRequest::builder().id(id).build();
                client.tag_by_id(&req).await?
            } else {
                let req = TagBySlugRequest::builder().slug(id).build();
                client.tag_by_slug(&req).await?
            };

            print_tag(&tag, &output)?;
        }

        TagsCommand::Related { id, omit_empty } => {
            let is_numeric = is_numeric_id(&id);
            let related = if is_numeric {
                let req = RelatedTagsByIdRequest::builder()
                    .id(id)
                    .maybe_omit_empty(omit_empty)
                    .build();
                client.related_tags_by_id(&req).await?
            } else {
                let req = RelatedTagsBySlugRequest::builder()
                    .slug(id)
                    .maybe_omit_empty(omit_empty)
                    .build();
                client.related_tags_by_slug(&req).await?
            };

            print_related_tags(&related, &output)?;
        }

        TagsCommand::RelatedTags { id, omit_empty } => {
            let is_numeric = is_numeric_id(&id);
            let tags = if is_numeric {
                let req = RelatedTagsByIdRequest::builder()
                    .id(id)
                    .maybe_omit_empty(omit_empty)
                    .build();
                client.tags_related_to_tag_by_id(&req).await?
            } else {
                let req = RelatedTagsBySlugRequest::builder()
                    .slug(id)
                    .maybe_omit_empty(omit_empty)
                    .build();
                client.tags_related_to_tag_by_slug(&req).await?
            };

            print_tags(&tags, &output)?;
        }
    }

    Ok(())
}
