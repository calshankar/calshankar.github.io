// @ts-check
import mermaid from 'astro-mermaid';
import starlight from '@astrojs/starlight';
import { defineConfig } from 'astro/config';

// https://astro.build/config
export default defineConfig({
	site: 'https://calshankar.github.io',
	integrations: [
		// Must come BEFORE starlight so ```mermaid fences are transformed
		mermaid({
			theme: 'neutral',
			autoTheme: true,
		}),
		starlight({
			title: 'Shankar Ramanathan',
			description:
				'Platform Engineering Leader and SRE Architect with 11+ years scaling cloud-native infrastructure, self-service Kubernetes platforms, and high-performing platform teams.',
			logo: {
				src: './src/assets/avatar.svg',
				replacesTitle: false,
			},
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/calshankar' },
				{
					icon: 'linkedin',
					label: 'LinkedIn',
					href: 'https://www.linkedin.com/in/shankar-ramanathan-a5715b9/',
				},
			],
			editLink: {
				baseUrl: 'https://github.com/calshankar/calshankar.github.io/edit/main/',
			},
			lastUpdated: true,
			pagination: false,
			tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
			customCss: ['./src/styles/custom.css'],
			head: [
				{
					tag: 'link',
					attrs: {
						rel: 'preconnect',
						href: 'https://fonts.googleapis.com',
					},
				},
				{
					tag: 'link',
					attrs: {
						rel: 'preconnect',
						href: 'https://fonts.gstatic.com',
						crossorigin: '',
					},
				},
				{
					tag: 'link',
					attrs: {
						rel: 'stylesheet',
						href: 'https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght,SOFT@9..144,300..900,0..100&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500;600;700&display=swap',
					},
				},
				{
					tag: 'meta',
					attrs: { property: 'og:image', content: 'https://calshankar.github.io/og-image.png' },
				},
				{
					tag: 'meta',
					attrs: { name: 'twitter:card', content: 'summary_large_image' },
				},
			],
			sidebar: [
				{ label: 'Home', link: '/' },
				// Projects hidden for now — re-enable when content is ready
				// {
				// 	label: 'Projects',
				// 	items: [{ autogenerate: { directory: 'projects' } }],
				// },
				{
					label: 'Blogs',
					items: [{ autogenerate: { directory: 'blogs' } }],
				},
				{ label: 'Tech Stack', slug: 'techstack' },
				{ label: 'About', slug: 'about' },
			],
		}),
	],
});
