use polymarket_client_sdk::gamma::types::response::{RelatedTag, Tag};
use tabled::settings::Style;
use tabled::{Table, Tabled};

use super::{
    DASH, OutputFormat, detail_field, format_date, print_detail_table, print_json, truncate,
};

#[derive(Tabled)]
struct TagRow {
    #[tabled(rename = "ID")]
    id: String,
    #[tabled(rename = "Label")]
    label: String,
    #[tabled(rename = "Slug")]
    slug: String,
    #[tabled(rename = "Carousel")]
    carousel: String,
}

fn tag_to_row(t: &Tag) -> TagRow {
    TagRow {
        id: truncate(&t.id, 20),
        label: t.label.as_deref().unwrap_or(DASH).into(),
        slug: t.slug.as_deref().unwrap_or(DASH).into(),
        carousel: t.is_carousel.map_or_else(|| DASH.into(), |v| v.to_string()),
    }
}

pub fn print_tags(tags: &[Tag], output: &OutputFormat) -> anyhow::Result<()> {
    match output {
        OutputFormat::Table => {
            if tags.is_empty() {
                println!("No tags found.");
                return Ok(());
            }
            let rows: Vec<TagRow> = tags.iter().map(tag_to_row).collect();
            let table = Table::new(rows).with(Style::rounded()).to_string();
            println!("{table}");
        }
        OutputFormat::Json => print_json(tags)?,
    }
    Ok(())
}

#[derive(Tabled)]
struct TagStatsRow {
    #[tabled(rename = "Label")]
    label: String,
    #[tabled(rename = "Slug")]
    slug: String,
    #[tabled(rename = "Markets")]
    market_count: String,
    #[tabled(rename = "Total Volume")]
    total_volume: String,
}

pub fn print_tags_with_stats(
    tag_stats: &[(Tag, usize, f64)],
    output: &OutputFormat,
) -> anyhow::Result<()> {
    match output {
        OutputFormat::Table => {
            if tag_stats.is_empty() {
                println!("No tags found.");
                return Ok(());
            }

            let rows: Vec<TagStatsRow> = tag_stats
                .iter()
                .map(|(tag, count, volume)| TagStatsRow {
                    label: tag.label.as_deref().unwrap_or(DASH).into(),
                    slug: tag.slug.as_deref().unwrap_or(DASH).into(),
                    market_count: count.to_string(),
                    total_volume: format_volume(*volume),
                })
                .collect();

            let table = Table::new(rows).with(Style::rounded()).to_string();
            println!("{table}");
        }
        OutputFormat::Json => {
            let json_data: Vec<serde_json::Value> = tag_stats
                .iter()
                .map(|(tag, count, volume)| {
                    serde_json::json!({
                        "id": tag.id,
                        "label": tag.label,
                        "slug": tag.slug,
                        "market_count": count,
                        "total_volume": volume,
                    })
                })
                .collect();
            print_json(&json_data)?;
        }
    }
    Ok(())
}

fn format_volume(volume: f64) -> String {
    // Handle -0.0 case
    let volume = if volume == 0.0 { 0.0 } else { volume };
    
    if volume >= 1_000_000_000.0 {
        format!("${:.1}B", volume / 1_000_000_000.0)
    } else if volume >= 1_000_000.0 {
        format!("${:.1}M", volume / 1_000_000.0)
    } else if volume >= 1_000.0 {
        format!("${:.1}K", volume / 1_000.0)
    } else {
        format!("${:.0}", volume)
    }
}

#[derive(Tabled)]
struct RelatedTagRow {
    #[tabled(rename = "ID")]
    id: String,
    #[tabled(rename = "Tag ID")]
    tag_id: String,
    #[tabled(rename = "Related Tag ID")]
    related_tag_id: String,
    #[tabled(rename = "Rank")]
    rank: String,
}

fn related_tag_to_row(r: &RelatedTag) -> RelatedTagRow {
    RelatedTagRow {
        id: truncate(&r.id, 20),
        tag_id: r.tag_id.as_deref().unwrap_or(DASH).into(),
        related_tag_id: r.related_tag_id.as_deref().unwrap_or(DASH).into(),
        rank: r.rank.map_or_else(|| DASH.into(), |v| v.to_string()),
    }
}

pub fn print_related_tags(tags: &[RelatedTag], output: &OutputFormat) -> anyhow::Result<()> {
    match output {
        OutputFormat::Table => {
            if tags.is_empty() {
                println!("No related tags found.");
                return Ok(());
            }
            let rows: Vec<RelatedTagRow> = tags.iter().map(related_tag_to_row).collect();
            let table = Table::new(rows).with(Style::rounded()).to_string();
            println!("{table}");
        }
        OutputFormat::Json => print_json(tags)?,
    }
    Ok(())
}

#[allow(clippy::vec_init_then_push)]
pub fn print_tag(t: &Tag, output: &OutputFormat) -> anyhow::Result<()> {
    if matches!(output, OutputFormat::Json) {
        return print_json(t);
    }
    let mut rows: Vec<[String; 2]> = Vec::new();

    detail_field!(rows, "ID", t.id.clone());
    detail_field!(rows, "Label", t.label.clone().unwrap_or_default());
    detail_field!(rows, "Slug", t.slug.clone().unwrap_or_default());
    detail_field!(
        rows,
        "Carousel",
        t.is_carousel.map(|v| v.to_string()).unwrap_or_default()
    );
    detail_field!(
        rows,
        "Force Show",
        t.force_show.map(|v| v.to_string()).unwrap_or_default()
    );
    detail_field!(
        rows,
        "Force Hide",
        t.force_hide.map(|v| v.to_string()).unwrap_or_default()
    );
    detail_field!(
        rows,
        "Created At",
        t.created_at.as_ref().map(format_date).unwrap_or_default()
    );
    detail_field!(
        rows,
        "Updated At",
        t.updated_at.as_ref().map(format_date).unwrap_or_default()
    );

    print_detail_table(rows);
    Ok(())
}
